const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const code = @import("ziggurat_code_editor");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlg_resource_count() u32;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn gtk_widget_size_allocate(*anyopaque, *const Allocation) void;
const Allocation = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_layer_test_pixel(*anyopaque, c_int, u32, u32) u32;
const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 760, .height = 360 };
const State = struct {
    window: z.Window = undefined,
    presenter: *code.Presenter = undefined,
    context: ui.Context = undefined,
    parameters: editing.Parameters = .{ .font = .{ .size = 16, .wrap = .word_character, .width = bounds.width } },
    failure: ?anyerror = null,
    expected: ?anyerror = null,
    fail_frame: bool = false,
    close_frame: bool = false,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value.err) |actual| {
            if (self.expected) |wanted| {
                if (actual != wanted) self.failure = actual;
            } else self.failure = actual;
        }
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        frame.clear(0xffffff);
        self.presenter.draw(frame, bounds, .{}) catch |err| {
            self.failure = err;
            return;
        };
        std.testing.expectError(error.ResourceInUse, self.presenter.close()) catch unreachable;
        std.testing.expectError(error.ResourceInUse, self.presenter.prepare(bounds, self.parameters)) catch unreachable;
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
        if (self.close_frame) _ = self.window.destroy() catch unreachable;
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        return self.presenter.handleEvent(event, bounds, self.parameters) catch |err| {
            self.failure = err;
            return true;
        };
    }
    fn paint(self: *State) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0) else {
            const native = self.window.app.windows.get(self.window.key).?.native.native.?;
            zlg_test_paint(native, 800, 400);
        }
        if (self.failure) |err| return err;
    }
    fn key(self: *State, key_value: z.KeyCode) !void {
        if (builtin.os.tag == .windows) {
            const native: usize = switch (key_value) {
                .up => c.VK_UP,
                .down => c.VK_DOWN,
                else => unreachable,
            };
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_KEYDOWN, native, 0);
        } else {
            const widget = gtk_bin_get_child(self.window.nativeHandle().?).?;
            const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const native_event: *KeyEvent = @ptrCast(@alignCast(event));
            native_event.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .state = 0, .keyval = switch (key_value) {
                .up => 0xff52,
                .down => 0xff54,
                else => unreachable,
            }, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "key-press-event", native_event, &handled);
            try std.testing.expect(handled != 0);
        }
        if (self.failure) |err| return err;
    }
};
fn publish(allocator: std.mem.Allocator, broker: *code.Broker) !void {
    const items: []const code.Completion = &.{
        .{ .label = "first", .detail = "first type", .documentation = "first documentation: 中 אבג\nsecond line", .edits = &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "first" }} },
        .{ .label = "second", .detail = "second type", .documentation = "second documentation: مرحبا 😀\n[plain](literal)", .edits = &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "second" }} },
        .{ .label = "empty", .edits = &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "empty" }} },
    };
    const job = try broker.begin(.completion, 3);
    try job.release();
    defer _ = broker.finish(job.ticket) catch unreachable;
    var result = try code.OwnedResult.init(allocator, .{ .completion = items }, .{});
    defer result.deinit();
    try broker.publish(job.ticket, &result);
}
fn rows(presenter: *code.Presenter) [3]*t.Prepared {
    var output: [3]*t.Prepared = undefined;
    for (&output, 0..) |*pointer, i| pointer.* = presenter.view.?.text[i].?.prepared;
    return output;
}
fn expectText(document: *d.Document, value: []const u8) !void {
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings(value, bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
}
const Hook = struct {
    const Mode = enum { none, scratch_edit, source_edit, source_close, source_quit, old_free_edit, accept_quit };
    child: std.mem.Allocator,
    mode: Mode = .none,
    client: *code.Presenter = undefined,
    adapter: *editing.Adapter,
    broker: *code.Broker,
    document: *d.Document,
    window: z.Window,
    length: usize = 0,
    hits: usize = 0,
    revision: u64 = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.child.rawAlloc(size, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const after_commit = if (self.mode == .accept_quit) if (self.document.version()) |version| version != self.revision else |_| false else false;
        if (self.mode != .none and (if (self.mode == .accept_quit) after_commit else bytes.len == self.length)) {
            const mode = self.mode;
            self.mode = .none;
            self.hits += 1;
            std.testing.expectError(error.Busy, self.client.close()) catch unreachable;
            std.testing.expectError(error.Busy, self.broker.borrow()) catch unreachable;
            if (mode == .accept_quit) std.testing.expectError(error.Busy, self.adapter.close()) catch unreachable else std.testing.expectError(error.ClientsAlive, self.adapter.close()) catch unreachable;
            switch (mode) {
                .scratch_edit, .source_edit, .old_free_edit => self.document.replace(.{ .start = 0, .end = 0 }, "!") catch unreachable,
                .source_close => {
                    _ = self.window.destroy() catch unreachable;
                },
                .source_quit => self.window.app.quit(),
                .accept_quit => self.window.app.quit(),
                .none => unreachable,
            }
        }
        self.child.rawFree(bytes, alignment, ra);
    }
};
fn reentry(allocator: std.mem.Allocator, mode: Hook.Mode) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var hook: Hook = .{ .child = allocator, .adapter = undefined, .broker = undefined, .document = document, .window = undefined };
    const adapter = try editing.Adapter.create(if (mode == .accept_quit) hook.allocator() else allocator, document, engine, .{ .metadata_history = 0 });
    hook.adapter = adapter;
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    hook.broker = broker;
    defer broker.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 800, .height = 400 });
    defer _ = window.destroy() catch unreachable;
    hook.window = window;
    const presenter = try code.Presenter.create(hook.allocator(), broker, adapter, engine, window, .{});
    defer presenter.close() catch unreachable;
    hook.client = presenter;
    const parameters: editing.Parameters = .{ .font = .{ .size = 16, .width = bounds.width, .wrap = .word_character } };
    _ = try adapter.setSelection(.{ .anchor = 3, .caret = 3 }, .downstream);
    try presenter.prepare(bounds, parameters);
    if (builtin.os.tag == .windows) window.show();
    try adapter.bind(window);
    defer {
        // A foreign callback can accept close/quit while the owner scope pins
        // this record. Complete native teardown before asking to unbind it.
        if (app.phase == .stopping) app.finishShutdown() catch unreachable else app.dispatch() catch unreachable;
        adapter.unbind() catch unreachable;
    }
    if (mode == .scratch_edit) try presenter.enableCompletionDetails(.{});
    try publish(allocator, broker);
    if (mode == .scratch_edit) {
        hook.length = presenter.limits.rectangles * @sizeOf(t.Rect);
    } else {
        try presenter.prepare(bounds, parameters);
        try presenter.enableCompletionDetails(.{});
        hook.length = "first type\n\nfirst documentation: 中 אבג\nsecond line".len;
        if (mode == .old_free_edit or mode == .accept_quit) {
            try presenter.prepare(bounds, parameters);
            if (mode == .old_free_edit) hook.length += 1; // The owning Layout stores a sentinel byte.
        }
    }
    hook.mode = mode;
    if (mode == .accept_quit) {
        hook.revision = try document.version();
        try std.testing.expect(try presenter.handleEvent(.{ .key_input = .{ .key = .enter } }, bounds, parameters));
        const outcome = (try presenter.lastAcceptance()).?;
        try std.testing.expect(outcome.edit.changed and outcome.stale_after_commit);
        try std.testing.expectEqual(hook.revision + 1, outcome.committed_revision);
        try std.testing.expectEqual(error.Closed, outcome.layout_error.?);
        try std.testing.expectEqual(error.Closed, (try presenter.lastLayoutError()).?);
        try expectText(document, "first");
    } else if (mode == .old_free_edit) {
        try std.testing.expect(try presenter.handleEvent(.{ .key_input = .{ .key = .down } }, bounds, parameters));
        try std.testing.expectEqual(@as(usize, 1), presenter.selected);
        try std.testing.expectEqual(error.StaleRevision, (try presenter.lastLayoutError()).?);
    } else {
        const expected: anyerror = if (mode == .source_close or mode == .source_quit) error.Closed else error.StaleRevision;
        const attempted = presenter.prepare(bounds, parameters);
        if (attempted) |_| std.debug.print("details reentry {s}: unexpected prepare success, App={s}, closed={}\n", .{ @tagName(mode), @tagName(app.phase), window.isClosed() }) else |_| {}
        try std.testing.expectError(expected, attempted);
    }
    try std.testing.expectEqual(@as(usize, 1), hook.hits);
    if (mode == .scratch_edit or mode == .source_edit) try expectText(document, "!abc");
}
fn pageNavigation(allocator: std.mem.Allocator, enabled: bool) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 800, .height = 400 });
    defer _ = window.destroy() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const presenter = try code.Presenter.create(failing.allocator(), broker, adapter, engine, window, .{ .popup_rows = 1 });
    defer presenter.close() catch unreachable;
    const parameters: editing.Parameters = .{ .font = .{ .size = 16, .width = bounds.width, .wrap = .word_character } };
    _ = try adapter.setSelection(.{ .anchor = 3, .caret = 3 }, .downstream);
    try presenter.prepare(bounds, parameters);
    if (builtin.os.tag == .windows) window.show();
    try adapter.bind(window);
    defer adapter.unbind() catch unreachable;
    try publish(allocator, broker);
    if (enabled) try presenter.enableCompletionDetails(.{});
    try presenter.prepare(bounds, parameters);
    failing.fail_index = failing.alloc_index;
    // Crossing a page commits the selected index before preparation too.
    try std.testing.expect(try presenter.handleEvent(.{ .key_input = .{ .key = .down } }, bounds, parameters));
    try std.testing.expectEqual(@as(usize, 1), presenter.selected);
    try std.testing.expectEqual(error.OutOfMemory, (try presenter.lastLayoutError()).?);
    failing.fail_index = std.math.maxInt(usize);
    try presenter.prepare(bounds, parameters);
    try std.testing.expectEqual(@as(usize, 1), (try presenter.overlayInfo()).selected_completion);
    try std.testing.expectEqual(@as(usize, 1), (try presenter.overlayInfo()).first_completion);
    try expectText(document, "abc");
}
fn pixel(renderer: *ui.SoftwareRenderer, x: u32, y: u32) !u32 {
    if (builtin.os.tag == .windows) {
        const value = c.GetPixel(renderer.dc, @intCast(x), @intCast(y));
        if (value == c.CLR_INVALID) return error.NoPixel;
        return ((value & 255) << 16) | (value & 0xff00) | ((value >> 16) & 255);
    }
    return zlc_test_raw_pixel(renderer.native.?, x, y);
}
fn panelHash(state: *State, box: ui.Rect) !u64 {
    var hash: u64 = 0xcbf29ce484222325;
    const scale = state.parameters.scale;
    if (builtin.os.tag == .windows and c.GdiFlush() == 0) return error.FlushFailed;
    for (0..@as(usize, @intFromFloat(60 * scale))) |y| for (0..@as(usize, @intFromFloat(140 * scale))) |x| {
        const xx: u32 = @as(u32, @intFromFloat(box.x * scale)) + @as(u32, @intCast(x));
        const yy: u32 = @as(u32, @intFromFloat(box.y * scale)) + @as(u32, @intCast(y));
        const value = if (builtin.os.tag == .windows) blk: {
            const front = state.context.renderer.layer_workspace.?.front();
            break :blk front.pixels.?[@as(usize, yy) * front.width + xx];
        } else zlc_layer_test_pixel(state.context.renderer.native.?, 1, xx, yy);
        hash = (hash ^ value) *% 0x100000001b3;
    };
    return hash;
}
fn refine(allocator: std.mem.Allocator, state: *State, broker: *code.Broker) !void {
    const choice = try state.presenter.completionChoice();
    var result = blk: {
        const borrow = try broker.borrow();
        defer borrow.end();
        const display = (try borrow.display(.completion)).?;
        var items: [3]code.Completion = undefined;
        @memcpy(&items, display.data.completion);
        items[choice.index].detail = "refined type";
        items[choice.index].documentation = "refined documentation: shaped 中 אבג";
        break :blk try code.OwnedResult.init(allocator, .{ .completion = &items }, .{});
    };
    defer result.deinit();
    var scope = try state.presenter.beginCompletionRefinement(choice);
    defer scope.end();
    const outcome = try scope.apply(&result);
    try std.testing.expect(outcome.published and !outcome.stale_after_commit);
}
fn pixels(state: *State) !void {
    const native_context = if (builtin.os.tag == .windows) c.GetDC(state.window.nativeHandle()) orelse return error.NoDC else blk: {
        const surface = cairo_image_surface_create(0, 1600, 800) orelse return error.NoSurface;
        const context = cairo_create(surface) orelse {
            cairo_surface_destroy(surface);
            return error.NoContext;
        };
        cairo_surface_destroy(surface);
        break :blk context;
    };
    defer if (builtin.os.tag == .windows) {
        _ = c.ReleaseDC(state.window.nativeHandle(), native_context);
    } else cairo_destroy(native_context);
    var draw_context = ui.Context.init(state, State.draw, State.action);
    defer draw_context.command_buffer.reset();
    var renderer: ui.SoftwareRenderer = .{};
    defer renderer.deinit();
    const original = state.parameters.scale;
    defer state.parameters.scale = original;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        state.parameters.scale = scale;
        try state.presenter.prepare(bounds, state.parameters);
        const box = (try state.presenter.overlayInfo()).details.?;
        const before = t.resourceCounts();
        var frame: ui.Frame = .{ .context = &draw_context, .size = .{ .width = @intFromFloat(800 * scale), .height = @intFromFloat(400 * scale), .scale = scale } };
        frame.clear(0xffffff);
        try state.presenter.draw(&frame, bounds, .{});
        if (frame.failure) |err| return err;
        try draw_context.command_buffer.finish();
        try std.testing.expectError(error.ResourceInUse, state.presenter.close());
        const paint: z.Paint = .{ .native_context = native_context, .native_window = if (builtin.os.tag == .windows) state.window.nativeHandle() else null, .size = frame.size };
        try renderer.begin(paint);
        try renderer.replayBuffer(&draw_context.command_buffer);
        try std.testing.expectEqual(@as(u32, 0xf3f5f8), try pixel(&renderer, @intFromFloat((box.x + box.width - 2) * scale), @intFromFloat((box.y + box.height - 2) * scale)));
        var ink: usize = 0;
        for (0..@as(usize, @intFromFloat(60 * scale))) |y| for (0..@as(usize, @intFromFloat(140 * scale))) |x| {
            const value = try pixel(&renderer, @as(u32, @intFromFloat((box.x + 4) * scale)) + @as(u32, @intCast(x)), @as(u32, @intFromFloat((box.y + 2) * scale)) + @as(u32, @intCast(y)));
            if (value != 0xf3f5f8) ink += 1;
        };
        try std.testing.expect(ink > 10);
        renderer.end(paint);
        draw_context.command_buffer.reset();
        try std.testing.expectEqual(before, t.resourceCounts());
    }
}
fn run(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{ .prepared = .{ .pixels = 2 * 1024 * 1024, .bytes = 16 * 1024 * 1024 } });
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    var state: State = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 800, .height = 400 });
    defer _ = state.window.destroy() catch unreachable;
    if (builtin.os.tag == .linux) {
        const widget = gtk_bin_get_child(state.window.nativeHandle().?).?;
        const allocation: Allocation = .{ .x = 0, .y = 0, .width = 800, .height = 400 };
        gtk_widget_size_allocate(widget, &allocation);
    }
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    _ = try adapter.setSelection(.{ .anchor = 3, .caret = 3 }, .downstream);
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    state.presenter = try code.Presenter.create(failing.allocator(), broker, adapter, engine, state.window, .{});
    defer state.presenter.close() catch unreachable;
    try state.presenter.prepare(bounds, state.parameters);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try state.context.prepareLayers(allocator, .{ .size = try state.window.contentSize() });
    try adapter.bind(state.window);
    defer adapter.unbind() catch unreachable;
    if (builtin.os.tag == .windows) state.window.show();
    try publish(allocator, broker);
    try state.presenter.prepare(bounds, state.parameters);
    const initial_rows = rows(state.presenter);
    const allocation_count = failing.alloc_index;
    failing.fail_index = allocation_count;
    try state.key(.down);
    try state.key(.up);
    try state.paint();
    try std.testing.expectEqual(allocation_count, failing.alloc_index);
    try std.testing.expect((try state.presenter.overlayInfo()).details == null);
    try std.testing.expectError(error.InvalidLimits, state.presenter.enableCompletionDetails(.{ .max_width = 1 }));
    try std.testing.expect(state.presenter.details_options == null);
    try state.presenter.enableCompletionDetails(.{});
    try state.presenter.enableCompletionRefinement();
    try std.testing.expectError(error.OutOfMemory, state.presenter.prepare(bounds, state.parameters));
    try std.testing.expectEqual(initial_rows, rows(state.presenter));
    failing.fail_index = std.math.maxInt(usize);
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expectEqual(initial_rows, rows(state.presenter));
    try std.testing.expectEqualStrings("first type\n\nfirst documentation: 中 אבג\nsecond line", try state.presenter.view.?.details_text.?.layout.text());
    var oom_count: usize = 0;
    for (0..128) |offset| {
        const before = t.resourceCounts();
        const old = state.presenter.view.?.details_text.?.prepared;
        state.presenter.details_required = true;
        failing.fail_index = failing.alloc_index + offset;
        state.presenter.prepare(bounds, state.parameters) catch |err| {
            if (err != error.OutOfMemory) return err;
            oom_count += 1;
            try std.testing.expectEqual(before, t.resourceCounts());
            try std.testing.expectEqual(old, state.presenter.view.?.details_text.?.prepared);
            try std.testing.expectEqual(initial_rows, rows(state.presenter));
            continue;
        };
        break;
    } else return error.NoSuccessfulDetailsCandidate;
    try std.testing.expect(oom_count > 5);
    failing.fail_index = std.math.maxInt(usize);
    const policy = state.presenter.details_options.?;
    const total = state.presenter.limits.bytes;
    const old_details = state.presenter.view.?.details_text.?.prepared;
    const resources = t.resourceCounts();
    state.presenter.details_options.?.text_bytes = 1;
    state.presenter.details_required = true;
    try std.testing.expectError(error.CapacityExceeded, state.presenter.prepare(bounds, state.parameters));
    state.presenter.details_options = policy;
    state.presenter.details_options.?.prepared.pixels = 1;
    try std.testing.expectError(error.PreparedCapacityExceeded, state.presenter.prepare(bounds, state.parameters));
    state.presenter.details_options = policy;
    state.presenter.limits.bytes = @sizeOf(code.Presenter) + state.presenter.view.?.reserved;
    try std.testing.expectError(error.CapacityExceeded, state.presenter.prepare(bounds, state.parameters));
    state.presenter.limits.bytes = total;
    try std.testing.expectEqual(old_details, state.presenter.view.?.details_text.?.prepared);
    try std.testing.expectEqual(initial_rows, rows(state.presenter));
    try std.testing.expectEqual(resources, t.resourceCounts());
    try state.presenter.prepare(bounds, state.parameters);
    const revision = try document.version();
    failing.fail_index = failing.alloc_index;
    try state.key(.down); // Selection commits once even when detail preparation fails.
    try std.testing.expectEqual(@as(usize, 1), state.presenter.selected);
    try std.testing.expectEqual(error.OutOfMemory, (try state.presenter.lastLayoutError()).?);
    try std.testing.expectError(error.LayoutRequired, state.presenter.overlayInfo());
    failing.fail_index = std.math.maxInt(usize);
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expectEqual(@as(usize, 1), (try state.presenter.overlayInfo()).selected_completion);
    try std.testing.expectEqual(initial_rows, rows(state.presenter));
    try std.testing.expectEqual(revision, try document.version());
    const box = (try state.presenter.overlayInfo()).details.?;
    const caret = (try adapter.positionRect(revision, 3, .downstream)).?;
    const original_point: z.Point = .{ .x = caret.x + 0.1, .y = caret.y + caret.height * 0.5 };
    const panel_point: z.Point = .{ .x = box.x + 10, .y = box.y + 10 };
    // A press on the existing caret keeps both revision and completion live.
    try std.testing.expect(try state.presenter.handleEvent(.{ .pointer_down = .{ .position = original_point } }, bounds, state.parameters));
    try std.testing.expectEqual(revision, try document.version());
    try std.testing.expect((try state.presenter.overlayInfo()).details != null);
    _ = try state.presenter.handleEvent(.{ .pointer_move = panel_point }, bounds, state.parameters);
    _ = try state.presenter.handleEvent(.{ .pointer_up = .{ .position = panel_point } }, bounds, state.parameters);
    const after_release = try document.version();
    _ = try state.presenter.handleEvent(.{ .pointer_move = .{ .x = bounds.x, .y = original_point.y } }, bounds, state.parameters);
    try std.testing.expectEqual(after_release, try document.version());
    try std.testing.expect(try state.presenter.handleEvent(.{ .pointer_down = .{ .position = .{ .x = box.x + 10, .y = box.y + 10 } } }, bounds, state.parameters));
    try std.testing.expect(try state.presenter.handleEvent(.{ .wheel = .{ .position = .{ .x = box.x + 10, .y = box.y + 10 }, .delta = .{ .x = 0, .y = 1 } } }, bounds, state.parameters));
    _ = try state.presenter.handleEvent(.{ .pointer_up = .{ .position = .{ .x = bounds.x, .y = original_point.y } } }, bounds, state.parameters);
    const after_panel_release = try document.version();
    _ = try state.presenter.handleEvent(.{ .pointer_move = .{ .x = bounds.x + 5, .y = original_point.y } }, bounds, state.parameters);
    try std.testing.expectEqual(after_panel_release, try document.version());
    for ([_]z.Event{ .cancel_input, .{ .focus = false } }) |terminal| {
        _ = try state.presenter.handleEvent(.{ .pointer_down = .{ .position = original_point } }, bounds, state.parameters);
        const before_terminal = try document.version();
        const borrow = try broker.borrow();
        const ended = state.presenter.handleEvent(terminal, bounds, state.parameters);
        borrow.end();
        try std.testing.expectError(error.Busy, ended);
        _ = try state.presenter.handleEvent(.{ .pointer_move = .{ .x = bounds.x, .y = original_point.y } }, bounds, state.parameters);
        try std.testing.expectEqual(before_terminal, try document.version());
    }
    failing.fail_index = failing.alloc_index;
    try state.key(.down); // Empty metadata creates no new text or heap.
    try state.key(.down); // End-of-list action cannot replay a previous step.
    try std.testing.expectEqual(@as(usize, 2), (try state.presenter.overlayInfo()).selected_completion);
    try std.testing.expect((try state.presenter.overlayInfo()).details == null);
    failing.fail_index = std.math.maxInt(usize);
    try state.key(.up);
    try pixels(&state);
    try state.presenter.prepare(bounds, state.parameters);
    try state.paint();
    const details_box = (try state.presenter.overlayInfo()).details.?;
    const old_hash = try panelHash(&state, details_box);
    const before_refine = rows(state.presenter);
    try refine(allocator, &state, broker);
    try std.testing.expectError(error.LayoutRequired, state.presenter.overlayInfo());
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expectEqual(before_refine, rows(state.presenter));
    try std.testing.expectEqualStrings("refined type\n\nrefined documentation: shaped 中 אבג", try state.presenter.view.?.details_text.?.layout.text());
    state.fail_frame = true;
    state.expected = error.InvalidGeometry;
    try state.paint();
    try std.testing.expectEqual(old_hash, try panelHash(&state, details_box));
    state.fail_frame = false;
    state.expected = null;
    try state.paint();
    try std.testing.expect(old_hash != try panelHash(&state, details_box));
    _ = try state.presenter.acceptCompletionOutcome(1);
    try expectText(document, "second");
    try std.testing.expect(try document.undo());
    try expectText(document, "abc");
    try state.presenter.prepare(bounds, state.parameters);
    try publish(allocator, broker);
    try state.presenter.prepare(bounds, state.parameters);
    _ = try state.presenter.handleEvent(.{ .text_preedit = .{ .text = "候选", .selection_start = 6, .selection_end = 6 } }, bounds, state.parameters);
    try std.testing.expect((try state.presenter.overlayInfo()).details == null);
    _ = try state.presenter.handleEvent(.text_preedit_cancel, bounds, state.parameters);
    try publish(allocator, broker);
    try state.presenter.prepare(bounds, state.parameters);
    try std.testing.expect((try state.presenter.overlayInfo()).details != null);
    state.close_frame = true;
    try state.paint();
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
fn isolatedWindows() !void {
    var name: [80]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "Ziggurat.CompletionDetails.{d}", .{c.GetCurrentProcessId()});
    var wide: [80:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null);
    if (desktop == null) return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    var executable: [32768:0]u16 = undefined;
    const count = c.GetModuleFileNameW(null, &executable, executable.len);
    if (count == 0 or count >= executable.len) return error.ExecutablePathUnavailable;
    var command: [32768:0]u16 = undefined;
    command[0] = '"';
    @memcpy(command[1 .. count + 1], executable[0..count]);
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child");
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
    if (c.WaitForSingleObject(process.hProcess, 60000) != c.WAIT_OBJECT_0) {
        _ = c.TerminateProcess(process.hProcess, 1);
        _ = c.WaitForSingleObject(process.hProcess, c.INFINITE);
        return error.TestProcessTimeout;
    }
    var exit_code: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0 or exit_code != 0) return error.TestProcessFailed;
}
pub fn main() !void {
    if (builtin.os.tag == .windows) {
        const args = try std.process.argsAlloc(std.heap.page_allocator);
        defer std.process.argsFree(std.heap.page_allocator, args);
        if (args.len == 1) return isolatedWindows();
        if (args.len != 2 or !std.mem.eql(u8, args[1], "--desktop-child")) return error.InvalidArgument;
    }
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    try run(debug.allocator());
    try pageNavigation(debug.allocator(), false);
    try pageNavigation(debug.allocator(), true);
    inline for ([_]Hook.Mode{ .scratch_edit, .source_edit, .source_close, .source_quit, .old_free_edit, .accept_quit }) |mode| try reentry(debug.allocator(), mode);
    try std.testing.expectEqual(t.ResourceCounts{}, t.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("completion details: explicit opt-in, row reuse, single navigation on OOM, metadata/plain text, 3DPI software pixels and unique undo, resources=0\n", .{});
}
