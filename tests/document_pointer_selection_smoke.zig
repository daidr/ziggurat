const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gtk_widget_grab_focus(*anyopaque) void;
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
const checkpoint_message = 0x8000 + 193;
const Case = enum { counts, drag, shift, clear, composition, recreate, presentation, ordinary };

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
            const surface = cairo_image_surface_create(0, 240, 140) orelse return error.SurfaceFailed;
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

const DocFree = struct {
    child: std.mem.Allocator,
    failing: *std.testing.FailingAllocator,
    armed: bool = false,
    hits: usize = 0,
    fn allocator(self: *DocFree) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *DocFree = @ptrCast(@alignCast(ptr));
        return self.child.rawAlloc(size, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *DocFree = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            self.armed = false;
            self.hits += 1;
            self.failing.fail_index = self.failing.alloc_index;
        }
        self.child.rawFree(bytes, alignment, ra);
    }
};
const Host = struct {
    allocator: std.mem.Allocator,
    case: Case,
    app: *z.App = undefined,
    window: z.Window = undefined,
    document: *d.Document,
    engine: *t.Engine,
    adapter: *editing.Adapter,
    failing: *std.testing.FailingAllocator,
    free_hook: *DocFree,
    parameters: editing.Parameters = .{ .font = .{ .word_ranges = true, .size = 16 } },
    a: z.Point = undefined,
    b: z.Point = undefined,
    failure: ?anyerror = null,
    stage: usize = 0,
    downs: usize = 0,
    ups: usize = 0,
    moves: usize = 0,
    committed_errors: usize = 0,
    mask: usize = 0,
    paint_armed: bool = false,
    old_input: z.PointerButtonInput = .{ .position = .{ .x = 0, .y = 0 } },

    fn fail(self: *Host, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("Document pointer {s} stage={d} downs={d} ups={d}: {s}\n", .{ @tagName(self.case), self.stage, self.downs, self.ups, @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.receive(window, value) catch |err| self.fail(err);
    }
    fn detach(_: *anyopaque) void {}
    fn message(ptr: *anyopaque, _: z.Window, kind: u32, _: usize, _: isize) ?isize {
        if (kind != checkpoint_message) return null;
        next(ptr);
        return 0;
    }
    fn serviceDestroy(_: *anyopaque) void {}
    fn selected(self: *Host, anchor: usize, caret: usize) !void {
        try std.testing.expectEqualDeep(d.Selection{ .anchor = anchor, .caret = caret }, try self.document.selection());
    }
    fn receive(self: *Host, window: z.Window, value: z.Event) !void {
        if (value == .paint and self.paint_armed) {
            self.paint_armed = false;
            try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(self.old_input.press, .down));
            self.mask += 1;
            const candidate = try editing.Adapter.create(self.allocator, self.document, self.engine, .{});
            var published = false;
            errdefer if (!published) candidate.close() catch unreachable;
            _ = try self.document.setSelection(.{ .anchor = source.len, .caret = source.len });
            _ = try candidate.prepare(bounds, self.parameters);
            try self.adapter.unbind();
            try self.adapter.close();
            self.adapter = candidate;
            published = true;
            try candidate.bind(window);
            try candidate.preparePointerSelection(window);
            return;
        }
        switch (value) {
            .pointer_down, .pointer_up, .pointer_move => {},
            else => {
                _ = try self.adapter.handleEvent(window, value, bounds, self.parameters);
                return;
            },
        }
        const result = try self.adapter.handlePointerEvent(window, value, bounds, self.parameters);
        if (self.case == .ordinary and value == .pointer_move) {
            const actual_selection = try self.document.selection();
            std.debug.print("ordinary post-up motion handled={} committed={} selection={d}:{d}\n", .{ result.handled, result.selection_committed, actual_selection.anchor, actual_selection.caret });
            try std.testing.expect(!result.handled and !result.selection_committed);
            self.moves += 1;
            return;
        }
        if (self.case == .clear and value == .pointer_up and self.ups < 2 or self.case == .recreate and value == .pointer_up and self.ups == 0) {
            try std.testing.expect(result.handled and !result.selection_committed and result.input_error != null);
            self.ups += 1;
            return;
        }
        if (result.input_error) |err| return err;
        if (result.presentation_error) |err| {
            if (self.case != .presentation or value != .pointer_down or self.downs != 0) return err;
            try std.testing.expect(err == error.LayoutRequired and result.selection_committed);
            try std.testing.expectEqual(@as(usize, 1), self.free_hook.hits);
            self.committed_errors += 1;
            self.failing.fail_index = std.math.maxInt(usize);
            _ = try self.adapter.prepare(bounds, self.parameters);
            const duplicate = try self.adapter.handlePointerEvent(window, value, bounds, self.parameters);
            try std.testing.expect(!duplicate.selection_committed and duplicate.input_error.? == error.AlreadyClaimed);
        }
        try std.testing.expect(result.handled and result.selection_committed);
        if (value == .pointer_down) {
            self.downs += 1;
            switch (self.case) {
                .counts => switch (self.downs) {
                    1, 4 => try self.selected(2, 2),
                    2 => try self.selected(0, 5),
                    3 => try self.selected(0, 13),
                    else => return error.TooManyDowns,
                },
                .drag => if (self.downs == 2) {
                    try self.selected(6, 10);
                } else {
                    try self.selected(8, 8);
                },
                .shift => if (self.downs == 2) {
                    try self.selected(2, 8);
                } else {
                    try self.selected(2, 2);
                },
                .clear => {
                    switch (self.downs) {
                        1 => {
                            try self.adapter.clearPointerSelection();
                            const replay = try self.adapter.handlePointerEvent(window, value, bounds, self.parameters);
                            try std.testing.expect(!replay.selection_committed and replay.input_error.? == error.StalePointerInput);
                        },
                        2 => try self.adapter.preparePointerSelection(window),
                        3 => try self.selected(2, 2),
                        4 => try self.selected(0, 5),
                        else => return error.TooManyDowns,
                    }
                },
                .composition => {
                    try std.testing.expect(try self.document.composition() == null);
                },
                .recreate => if (self.downs == 1) {
                    self.old_input = value.pointer_down;
                    self.paint_armed = true;
                    try Native.paint(window);
                    if (self.failure) |err| return err;
                    const replay = try self.adapter.handlePointerEvent(window, value, bounds, self.parameters);
                    try std.testing.expect(!replay.selection_committed and replay.input_error.? == error.StalePointerInput);
                    try self.selected(source.len, source.len);
                },
                .presentation, .ordinary => {},
            }
        } else if (value == .pointer_up) {
            self.ups += 1;
        } else {
            self.moves += 1;
            if (self.moves == 1) try self.selected(10, 0) else try self.selected(6, 10);
        }
    }
    fn pair(self: *Host, point: z.Point, tick: u32, shift: bool) !void {
        try Native.button(self.window, point, .down, tick, shift);
        try Native.button(self.window, point, .up, tick + 1, shift);
    }
    fn start(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.begin() catch |err| self.fail(err);
    }
    fn begin(self: *Host) !void {
        if (builtin.os.tag == .windows) {
            _ = c.SetFocus(self.window.nativeHandle());
            try std.testing.expect(c.GetFocus() == self.window.nativeHandle());
        } else gtk_widget_grab_focus(try Native.area(self.window));
        if (self.case == .composition) _ = try self.adapter.handleEvent(self.window, .{ .text_preedit = .{ .text = "X", .selection_start = 0, .selection_end = 0 } }, bounds, self.parameters);
        if (self.case == .presentation) self.free_hook.armed = true;
        if (self.case == .ordinary) try self.adapter.clearPointerSelection();
        try self.queueStage();
    }
    fn queueStage(self: *Host) !void {
        const tick: u32 = @intCast(20 * self.stage);
        if (self.case == .ordinary and self.stage == 1) {
            try Native.move(self.window, self.b, tick, false);
        } else if (self.case == .drag) {
            switch (self.stage) {
                0 => try self.pair(self.b, tick, false),
                1 => {
                    try Native.button(self.window, self.b, .down, tick, false);
                    try Native.move(self.window, self.a, tick + 1, true);
                },
                2 => {
                    try Native.move(self.window, self.b, tick, true);
                    try Native.button(self.window, self.b, .up, tick + 1, false);
                },
                3 => try self.pair(self.b, tick, false),
                else => unreachable,
            }
        } else try self.pair(if ((self.case == .shift or self.case == .clear) and self.stage == 1) self.b else self.a, tick, self.case == .shift and self.stage == 1);
        try Native.checkpoint(self);
    }
    fn next(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.advance() catch |err| self.fail(err);
    }
    fn advance(self: *Host) !void {
        if (self.failure) |err| return err;
        self.stage += 1;
        const count: usize = switch (self.case) {
            .counts, .drag, .clear => 4,
            .shift, .composition, .ordinary => 2,
            .recreate => 3,
            .presentation => 1,
        };
        if (self.stage < count) return self.queueStage();
        try std.testing.expectEqual(self.downs, self.ups);
        if (self.case == .recreate) try std.testing.expectEqual(@as(usize, 1), self.mask);
        if (self.case == .presentation) try std.testing.expectEqual(@as(usize, 1), self.committed_errors);
        self.app.quit();
    }
};

fn scenario(allocator: std.mem.Allocator, case: Case) !void {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var hook: DocFree = .{ .child = allocator, .failing = &failing };
    const document = try d.Document.create(hook.allocator(), std.Thread.getCurrentId(), source, .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var host: Host = .{ .allocator = allocator, .case = case, .document = document, .engine = engine, .adapter = try editing.Adapter.create(failing.allocator(), document, engine, .{}), .failing = &failing, .free_hook = &hook };
    defer host.adapter.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    host.app = app;
    host.window = try app.createWindow(.{ .width = 240, .height = 140, .native_pointer_clicks = true });
    host.parameters.scale = (try host.window.contentSize()).scale;
    try host.window.setContent(.{ .context = &host, .event = Host.event, .detach = Host.detach });
    if (builtin.os.tag == .windows) try host.window.setService(.{ .context = &host, .message = Host.message, .native_destroying = Host.serviceDestroy });
    if (case == .presentation) _ = try document.setSelections(&.{ .{ .anchor = 0, .caret = 1 }, .{ .anchor = 6, .caret = 7 } }, 0);
    _ = try host.adapter.prepare(bounds, host.parameters);
    try host.adapter.bind(host.window);
    defer host.adapter.unbind() catch unreachable;
    try host.adapter.preparePointerSelection(host.window);
    const layout = try engine.layout(source, host.parameters.font);
    const a = try layout.caret(.{ .byte_offset = 2 });
    const b = try layout.caret(.{ .byte_offset = 8 });
    host.a = .{ .x = bounds.x + a.x, .y = bounds.y + a.y + a.height * 0.5 };
    host.b = .{ .x = bounds.x + b.x, .y = bounds.y + b.y + b.height * 0.5 };
    try layout.close();
    try app.post(.{ .context = &host, .call = Host.start });
    try app.run();
    if (host.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("Document pointer native {s}: downs={d}/ups={d} moves={d} mask={d} committed_errors={d} records=0\n", .{ @tagName(case), host.downs, host.ups, host.moves, host.mask, host.committed_errors });
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

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var args = try init.args.iterateAllocator(gpa.allocator());
    defer args.deinit();
    _ = args.next();
    var child = false;
    if (args.next()) |argument| {
        if (!std.mem.eql(u8, argument, "--desktop-child")) return error.InvalidArgument;
        child = true;
    }
    if (args.next() != null) return error.InvalidArgument;
    if (builtin.os.tag == .windows and !child) return isolatedWindows();
    // The actual native queue/GTK adapter supplies facts, not a Zig claim.
    const before = t.resourceCounts();
    inline for (std.meta.tags(Case)) |case| {
        try scenario(gpa.allocator(), case);
        if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
        try std.testing.expectEqualDeep(before, t.resourceCounts());
    }
    try @import("document_surface_fixture.zig").run(Native, gpa.allocator());
}
