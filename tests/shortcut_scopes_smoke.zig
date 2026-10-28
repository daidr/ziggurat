const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn zgpu_resource_count() u32;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
extern fn gdk_window_focus(*anyopaque, u32) void;
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
const Native = struct {
    fn area(window: z.Window) *anyopaque {
        return gtk_bin_get_child(window.nativeHandle().?).?;
    }
    fn focus(window: z.Window) !void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            _ = c.SetFocus(hwnd);
            if (c.GetFocus() != hwnd) return error.NativeFocusUnavailable;
        }
        try std.testing.expect((try window.state()).focused);
    }
    fn paint(window: z.Window) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            _ = c.InvalidateRect(hwnd, null, 0);
            _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
        } else {
            const size = window.contentSize() catch unreachable;
            const factor: u32 = @intFromFloat(size.scale);
            std.debug.assert(factor != 0 and size.width % factor == 0 and size.height % factor == 0);
            zlg_test_paint(window.app.windows.get(window.key).?.native.native.?, size.width / factor, size.height / factor);
        }
    }
    fn key(window: z.Window, key_input: z.KeyInput) !void {
        if (builtin.os.tag == .windows) {
            const code: c.WPARAM = switch (key_input.key) {
                .f3 => c.VK_F3,
                .f4 => c.VK_F4,
                .escape => c.VK_ESCAPE,
                else => return error.UnsupportedTestKey,
            };
            var saved: [256]u8 = undefined;
            if (c.GetKeyboardState(&saved) == 0) return error.KeyboardStateUnavailable;
            defer _ = c.SetKeyboardState(&saved);
            var clean: [256]u8 = @splat(0);
            clean[c.VK_SHIFT] = if (key_input.modifiers.shift) 0x80 else 0;
            clean[c.VK_CONTROL] = if (key_input.modifiers.control) 0x80 else 0;
            clean[c.VK_MENU] = if (key_input.modifiers.alt) 0x80 else 0;
            if (c.SetKeyboardState(&clean) == 0) return error.KeyboardStateUnavailable;
            const hwnd: c.HWND = window.nativeHandle();
            const flags: c.LPARAM = if (key_input.repeat) 1 << 30 else 0;
            _ = c.SendMessageW(hwnd, if (key_input.modifiers.alt) c.WM_SYSKEYDOWN else c.WM_KEYDOWN, code, flags);
            if (!window.isClosed()) _ = c.SendMessageW(hwnd, if (key_input.modifiers.alt) c.WM_SYSKEYUP else c.WM_KEYUP, code, flags | 1 << 31);
        } else {
            const code: c_uint = switch (key_input.key) {
                .f3 => 0xffc0,
                .f4 => 0xffc1,
                .escape => 0xff1b,
                else => return error.UnsupportedTestKey,
            };
            const widget = area(window);
            const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const native: *KeyEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .state = (if (key_input.modifiers.shift) @as(c_uint, 1) else 0) | (if (key_input.modifiers.control) @as(c_uint, 4) else 0) | (if (key_input.modifiers.alt) @as(c_uint, 8) else 0), .keyval = code, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "key-press-event", native, &handled);
        }
    }
};
const Case = enum { success, fallback, rejected, superseded, control_focus_cycle, close_before_take, close_action };
const Host = struct {
    allocator: std.mem.Allocator,
    app: *z.App = undefined,
    window: z.Window = undefined,
    context: ?*ui.Context = null,
    case: Case,
    failure: ?anyerror = null,
    request: ?ui.ShortcutRequestToken = null,
    overlay: bool = false,
    actions: usize = 0,
    last: u64 = 0,
    fallbacks: usize = 0,
    closed: usize = 0,
    diagnostics: usize = 0,
    inputs: usize = 0,
    phase: u8 = 0,
    started: bool = false,
    padding: usize = 0,
    renderer: ui.RenderMode = .gdi,
    gpu_frames: usize = 0,
    presents: u32 = 0,

    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.project(frame) catch |err| {
            self.failure = err;
        };
    }
    fn project(self: *@This(), frame: *ui.Frame) !void {
        frame.rect(.{ .x = 0, .y = 0, .width = 160, .height = 40 }, 0x18304a);
        const box: ui.Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
        try frame.addControl(1, box, .{ .shortcut = .{ .key = .f3 } });
        if (self.case != .fallback) try frame.addControl(6, .{ .x = 25, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .escape } });
        try frame.beginShortcutScope(10, .{});
        try frame.addControl(2, .{ .x = 50, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } });
        try frame.endShortcutScope();
        try frame.beginShortcutScope(20, .{ .kind = .overlay, .overlay_order = 1 });
        try frame.addControl(3, .{ .x = 75, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f4 } });
        try frame.endShortcutScope();
        try frame.beginShortcutScope(30, .{ .kind = .overlay, .overlay_order = 2 });
        try frame.addControl(4, .{ .x = 100, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f4 } });
        if (self.overlay and self.case != .fallback) try frame.addControl(5, .{ .x = 125, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .escape } });
        try frame.endShortcutScope();
        if (self.request) |request| try frame.acceptShortcutRequest(request);
        if (self.overlay and self.case == .rejected) try frame.beginShortcutScope(40, .{}); // Full candidate must fail, preserving the actual old renderer front.
    }
    fn action(ptr: *anyopaque, id: u64) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.actions += 1;
        self.last = id;
        if (id == 5 or id == 6) {
            self.request = null;
            if (self.case == .close_action) _ = self.window.destroy() catch |err| {
                self.failure = err;
            };
        }
    }
    fn fallback(ptr: *anyopaque, _: z.Window, _: z.KeyInput) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.fallbacks += 1;
        self.request = null;
    }
    fn input(ptr: *anyopaque, context: *ui.Context, ev: z.Event) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (builtin.os.tag == .linux and ev == .focus and ev.focus and !self.started) {
            self.started = true;
            self.app.post(.{ .context = self, .call = start }) catch |err| {
                self.failure = err;
                self.app.quit();
            };
        }
        if (ev == .key_input) {
            self.inputs += 1;
            if (ev.key_input.key == .escape and !ev.key_input.repeat) {
                self.overlay = true; // Explicit update stage, before draw.
                self.request = context.deferUnhandledEscape() catch |err| {
                    self.failure = err;
                    return true;
                };
            }
        }
        return false;
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.case == .rejected and value.operation == .paint and if (value.err) |err| err == error.InvalidShortcutFrame else false) self.diagnostics += 1 else {
            self.failure = value.err orelse error.UnexpectedDiagnostic;
            std.debug.print("scope native diagnostic: {any}\n", .{value});
        }
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const context = self.context.?;
        self.context = null;
        self.closed += 1;
        self.allocator.destroy(context);
        if (self.case == .close_before_take) self.app.post(.{ .context = self, .call = finish }) catch |err| {
            self.failure = err;
            self.app.quit();
        };
    }
    fn start(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.begin() catch |err| {
            std.debug.print("scope begin phase={d}, actions={d}, last={d}, inputs={d}: {any}\n", .{ self.phase, self.actions, self.last, self.inputs, err });
            self.failure = err;
            self.app.quit();
        };
    }
    fn pad(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.padding += 1;
    }
    fn begin(self: *@This()) !void {
        self.phase = 1;
        try Native.focus(self.window);
        self.phase = 2;
        Native.paint(self.window);
        if (self.failure) |err| return err;
        try self.observeRenderer();
        _ = try self.context.?.shortcutScope(10); // Real renderer success published it.
        self.phase = 3;
        try self.context.?.focusControl(2);
        self.phase = 4;
        try Native.key(self.window, .{ .key = .f3 });
        try std.testing.expectEqual(@as(u64, 2), self.last);
        self.phase = 5;
        try Native.key(self.window, .{ .key = .f4 });
        try std.testing.expectEqual(@as(u64, 4), self.last);
        self.phase = 6;
        const count = self.actions;
        try Native.key(self.window, .{ .key = .f3, .modifiers = .{ .control = true } });
        try std.testing.expectEqual(count, self.actions);
        self.actions = 0;
        self.last = 0;
        self.phase = 7;
        try Native.key(self.window, .{ .key = .escape });
        if (self.failure) |err| return err;
        try std.testing.expect(self.request != null);
        self.phase = 8;
        // Start is the first task in Core's bounded 256-task drain. Leave the
        // continuation beyond that batch so destruction has an actual native
        // safe point before it is taken. No nested dispatch or wait is used.
        if (self.case == .close_before_take) for (0..255) |_| try self.app.post(.{ .context = self, .call = pad });
        Native.paint(self.window);
        if (self.failure) |err| return err;
        try self.observeRenderer();
        try std.testing.expectEqual(@as(usize, 0), self.actions + self.fallbacks);
        if (self.case == .superseded) {
            self.request = null;
            self.overlay = false;
            Native.paint(self.window);
        } else if (self.case == .control_focus_cycle) {
            try self.context.?.focusControl(4);
            try self.context.?.focusControl(2);
        } else if (self.case == .close_before_take) {
            _ = try self.window.destroy();
            // on_closed posts finish after freeing Context at the batch-safe
            // point. Closing-in-progress alone cannot authorize free.
        }
        if (self.case != .close_before_take) try self.app.post(.{ .context = self, .call = finish });
    }
    fn observeRenderer(self: *@This()) !void {
        const context = self.context.?;
        if (self.renderer == .gdi) {
            try std.testing.expect(context.gdi_frames > 0);
            try std.testing.expectEqual(@as(usize, 0), context.gpu_frames);
            return;
        }
        if (comptime builtin.os.tag == .windows and ui.capabilities.gpu) {
            const stats = context.gpu_renderer.stats();
            try std.testing.expect(context.gpu_frames > 0 and stats.device_creations > 0 and stats.target_creations > 0 and stats.presents > 0);
            try std.testing.expectEqual(@as(usize, 0), context.gdi_frames);
            try std.testing.expectEqual(@as(usize, 0), context.fallbacks);
            self.gpu_frames = context.gpu_frames;
            self.presents = stats.presents;
        } else return error.UnsupportedTestRenderer;
    }
    fn finish(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.check() catch |err| {
            std.debug.print("scope check actions={d}, last={d}, fallback={d}, inputs={d}: {any}\n", .{ self.actions, self.last, self.fallbacks, self.inputs, err });
            self.failure = err;
        };
        self.app.quit();
    }
    fn check(self: *@This()) !void {
        if (self.case == .close_before_take) {
            try std.testing.expect(self.context == null and self.closed == 1);
            try std.testing.expectEqual(@as(usize, 255), self.padding);
        }
        const acted = self.case == .success or self.case == .rejected or self.case == .close_action;
        try std.testing.expectEqual(@as(usize, if (acted) 1 else 0), self.actions);
        if (acted) try std.testing.expectEqual(@as(u64, if (self.case == .rejected) 6 else 5), self.last);
        try std.testing.expectEqual(@as(usize, if (self.case == .fallback) 1 else 0), self.fallbacks);
        if (self.case == .rejected) try std.testing.expect(self.diagnostics != 0);
        try std.testing.expectEqual(@as(usize, 4), self.inputs);
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    var args = try init.args.iterateAllocator(allocator.allocator());
    defer args.deinit();
    _ = args.next();
    var renderer: ui.RenderMode = .gdi;
    if (args.next()) |flag| {
        if (!std.mem.eql(u8, flag, "--renderer")) return error.InvalidArguments;
        const value = args.next() orelse return error.InvalidArguments;
        renderer = if (std.mem.eql(u8, value, "gdi")) .gdi else if (std.mem.eql(u8, value, "hardware")) .hardware else if (std.mem.eql(u8, value, "warp")) .warp else return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;
    }
    if (renderer != .gdi and (builtin.os.tag != .windows or !ui.capabilities.gpu)) return error.UnsupportedTestRenderer;
    inline for (std.meta.tags(Case)) |case| {
        errdefer std.debug.print("shortcut native case: {s}\n", .{@tagName(case)});
        var host: Host = .{ .allocator = allocator.allocator(), .case = case, .renderer = renderer };
        // Independent of Context/Host fields and alive through App.deinit.
        var workspace_allocator = std.testing.FailingAllocator.init(allocator.allocator(), .{});
        const app = try z.App.initWithOptions(allocator.allocator(), .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
        defer app.deinit();
        host.app = app;
        const window = try app.createWindow(.{ .width = 320, .height = 200, .on_closed = .{ .context = &host, .notify = Host.onClosed } });
        host.window = window;
        const context = try allocator.allocator().create(ui.Context);
        host.context = context;
        context.* = ui.Context.init(&host, Host.draw, Host.action);
        context.render_mode = renderer;
        context.on_input = Host.input;
        try context.attach(window);
        try context.prepareShortcutScopes(workspace_allocator.allocator(), .{ .unhandled = .{ .context = &host, .call = Host.fallback } });
        workspace_allocator.fail_index = workspace_allocator.alloc_index;
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        if (builtin.os.tag == .linux) {
            // Isolated Xvfb only. A mapped GTK top-level and real GDK focus
            // delivery are necessary for Window.state().focused authority.
            window.show();
            try window.perform(.focus);
            gdk_window_focus(gtk_widget_get_window(window.nativeHandle().?).?, 0);
        } else try app.post(.{ .context = &host, .call = Host.start });
        try app.run();
        try std.testing.expect(!watchdog.expired);
        if (host.failure) |err| return err;
        try std.testing.expectEqual(@as(usize, 1), host.closed);
        try std.testing.expect(host.context == null);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
        try std.testing.expectEqual(@as(usize, 1), workspace_allocator.allocations);
        try std.testing.expectEqual(@as(usize, 1), workspace_allocator.deallocations);
        try std.testing.expectEqual(workspace_allocator.allocated_bytes, workspace_allocator.freed_bytes);
        try std.testing.expect(!workspace_allocator.has_induced_failure);
        if (renderer != .gdi) try std.testing.expect(host.gpu_frames > 0 and host.presents > 0);
    }
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    if (comptime builtin.os.tag == .windows and ui.capabilities.gpu) try std.testing.expectEqual(@as(u32, 0), zgpu_resource_count());
    std.debug.print("shortcut scopes native smoke passed: 7 cases; renderer={s}; real fronts, nested/overlay keys, Escape continuation/fallback/failure/supersession/focus cycle, callback close, immediate Context free, scope allocations=1/frees=1 per case\n", .{@tagName(renderer)});
}
