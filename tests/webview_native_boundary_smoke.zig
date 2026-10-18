const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else @cImport({
    @cInclude("gtk/gtk.h");
});

const Mode = enum { normal, close };
const html = "<!doctype html><meta charset=utf-8><title>Native callback boundary</title><p>Owned fixture</p>";

// This observer survives both Windows, the heap View owner and App.deinit.
// The native completion may close B; A's outer input borrow stays independent.
const State = struct {
    app: *z.App = undefined,
    app_ready: bool = false,
    a: z.Window = undefined,
    b: z.Window = undefined,
    host: ?*Host = null,
    mode: Mode,
    failure: ?anyerror = null,
    press: z.PointerPress = .{},
    inside_replace: bool = false,
    queued: bool = false,
    sending: bool = false,
    downs: usize = 0,
    ups: usize = 0,
    completions: usize = 0,
    masked: usize = 0,
    borrowed: usize = 0,
    restored: usize = 0,
    a_detached: usize = 0,
    a_closed: usize = 0,
    b_closed: usize = 0,
    host_frees: usize = 0,

    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("WebView native boundary {s}: {s}\n", .{ @tagName(self.mode), @errorName(err) });
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.fail(value.err orelse error.UnexpectedDiagnostic);
        if (self.app_ready) self.app.quit();
    }
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.sending) std.debug.print("WebView native boundary A during-send event={s}\n", .{@tagName(std.meta.activeTag(value))});
        self.receive(window, value) catch |err| self.fail(err);
    }
    fn receive(self: *State, window: z.Window, value: z.Event) !void {
        if (value == .pointer_up) {
            self.ups += 1;
            return;
        }
        if (value != .pointer_down) return;
        self.downs += 1;
        try std.testing.expectEqual(@as(usize, 1), self.downs);
        const input = value.pointer_down;
        try std.testing.expect(input.button == .primary and input.press.sequence != 0);
        self.press = input.press;
        const original = try window.pointerPressSnapshot(input.press, .down);
        const record = window.app.windows.get(window.key) orelse return error.MissingWindowRecord;
        const operation = record.pointerOperation();
        try std.testing.expect(operation != 0 and operation != std.math.maxInt(u64));
        const host = self.host orelse return error.MissingViewOwner;

        // This is a real public -> native adapter -> registered C ABI -> Zig
        // completion chain. With no old script, the adapter retires directly;
        // this does not claim to observe an SDK asynchronous Add completion.
        // In particular, neither completion nor a pointer callback is called
        // directly by this fixture. The empty batch retires synchronously.
        self.inside_replace = true;
        _ = host.view.replaceDocumentInitializers(&.{}, .{ .context = self, .complete = completed }) catch |err| {
            self.inside_replace = false;
            return err;
        };
        self.inside_replace = false;
        try std.testing.expectEqual(@as(usize, 1), self.completions);
        try std.testing.expectEqual(operation, record.pointerOperation());
        try std.testing.expectEqualDeep(original, try window.pointerPressSnapshot(input.press, .down));
        self.restored += 1;
        // No Host/View access after replace: close mode may have freed it.
    }
    fn completed(ptr: *anyopaque, result: web.InitializerResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.checkCompletion(result) catch |err| self.fail(err);
    }
    fn checkCompletion(self: *State, result: web.InitializerResult) !void {
        self.app.assertOwner();
        self.completions += 1;
        try std.testing.expect(self.inside_replace and self.completions == 1);
        if (result != .installed) return error.ExpectedInstalled;
        if (self.a.pointerPressSnapshot(self.press, .down)) |_| {
            self.borrowed += 1;
            self.fail(error.ExpectedNativeCallbackMasked);
        } else |err| {
            if (err != error.StalePointerInput) return err;
            self.masked += 1;
        }
        if (self.mode == .close) {
            try std.testing.expectEqual(z.CloseResult.deferred, try self.b.destroy());
            try std.testing.expectEqual(@as(usize, 0), self.host_frees);
        }
    }
    fn detached(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.a_detached += 1;
    }
    fn closedA(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.a_closed += 1;
    }
    fn send(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.sendNativePair() catch |err| self.fail(err);
        self.app.quit();
    }
    fn sendNativePair(self: *State) !void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = @ptrCast(self.a.nativeHandle());
            _ = c.SetFocus(hwnd);
            if (c.GetFocus() != hwnd) return error.ThreadFocusUnavailable;
            _ = c.SendMessageW(hwnd, c.WM_LBUTTONDOWN, c.MK_LBUTTON, 20 | (20 << 16));
            if (!self.a.isClosed()) _ = c.SendMessageW(hwnd, c.WM_LBUTTONUP, 0, 20 | (20 << 16));
        } else {
            const window: *c.GtkWidget = @ptrCast(@alignCast(self.a.nativeHandle() orelse return error.MissingNativeWindow));
            const area = c.gtk_bin_get_child(@ptrCast(window)) orelse return error.MissingDrawingArea;
            // Emit the real GTK button signal registered by the linked ordinary
            // adapter. The generic gtk_widget_event filtered this synthetic
            // PRESS before that translator (operation stayed zero); do not call
            // the Zig callback or fabricate a Core receipt as a substitute.
            // Deterministic signal facts are not human input/device-clock proof.
            const saved = c.g_object_ref(area) orelse return error.MissingDrawingArea;
            defer c.g_object_unref(saved);
            c.gtk_widget_grab_focus(area);
            const native = c.gtk_widget_get_window(area) orelse return error.MissingGdkWindow;
            var native_event: c.GdkEventButton = std.mem.zeroes(c.GdkEventButton);
            native_event.type = c.GDK_BUTTON_PRESS;
            native_event.window = native;
            native_event.send_event = 1;
            native_event.button = 1;
            native_event.time = 123;
            native_event.x = 20;
            native_event.y = 20;
            native_event.x_root = 20;
            native_event.y_root = 20;
            const record = self.app.windows.get(self.a.key) orelse return error.MissingWindowRecord;
            std.debug.print("WebView native boundary GTK prepared focused={} operation={d}\n", .{ c.gtk_widget_has_focus(area), record.pointerOperation() });
            self.sending = true;
            defer self.sending = false;
            var down: c_int = 0;
            c.g_signal_emit_by_name(area, "button-press-event", &native_event, &down);
            std.debug.print("WebView native boundary GTK down return={d} operation={d} downs={d}\n", .{ down, record.pointerOperation(), self.downs });
            if (!self.a.isClosed()) {
                native_event.type = c.GDK_BUTTON_RELEASE;
                native_event.time = 124;
                native_event.state = c.GDK_BUTTON1_MASK;
                var up: c_int = 0;
                c.g_signal_emit_by_name(area, "button-release-event", &native_event, &up);
            }
        }
    }
};

const Host = struct {
    allocator: std.mem.Allocator,
    observer: *State,
    view: web.View,

    fn event(ptr: *anyopaque, _: *web.View, value: web.Event) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (value == .failed or value == .process_failed) {
            self.observer.fail(error.WebViewFailed);
            self.observer.app.quit();
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (value != .completed) return;
        const observer = self.observer;
        if (!value.completed.success) {
            observer.fail(error.DocumentLoadFailed);
            observer.app.quit();
            return;
        }
        if (observer.queued) {
            observer.fail(error.DuplicateDocument);
            observer.app.quit();
            return;
        }
        observer.queued = true;
        observer.app.post(.{ .context = observer, .call = State.send }) catch |err| {
            observer.fail(err);
            observer.app.quit();
        };
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        const observer = self.observer;
        const allocator = self.allocator;
        observer.host = null;
        observer.b_closed += 1;
        observer.host_frees += 1;
        allocator.destroy(self);
    }
};

fn scenario(allocator: std.mem.Allocator, mode: Mode, profile: []const u8) !void {
    var observer: State = .{ .mode = mode };
    {
        const app = try z.App.initWithOptions(allocator, .{ .icon_policy = .disabled, .diagnostics_sink = .{ .context = &observer, .emit = State.diagnostic } });
        defer app.deinit();
        observer.app = app;
        observer.app_ready = true;
        observer.a = try app.createWindow(.{ .native_pointer_clicks = true, .title = "Native boundary raw A", .width = 180, .height = 100, .on_closed = .{ .context = &observer, .notify = State.closedA } });
        try observer.a.setContent(.{ .context = &observer, .event = State.event, .detach = State.detached });
        const host = try allocator.create(Host);
        var owns_host = true;
        errdefer if (owns_host) allocator.destroy(host);
        host.* = .{ .allocator = allocator, .observer = &observer, .view = undefined };
        host.view = web.View.init(allocator, host, Host.event);
        observer.host = host;
        observer.b = try app.createWindow(.{ .title = "Native boundary WebView B", .width = 180, .height = 100, .on_closed = .{ .context = host, .notify = Host.closed } });
        owns_host = false; // B.on_closed now owns Host, including attach failure.
        try host.view.attach(observer.b, .{ .html = html, .storage = if (builtin.os.tag == .linux) .ephemeral else .profile, .user_data_folder = profile, .page_listener = .{ .context = host, .event = Host.page } });
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop(); // App.run has returned before joining the driver.
        try app.run();
        watchdog.stop();
        if (watchdog.expired) observer.fail(error.Timeout);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    const native = web.resourceCounts();
    const initializers = web.initializerNativeCounts();
    std.debug.print("WebView native boundary {s}: down={d} up={d} completion={d} masked={d} borrowed={d} restored={d} detach={d} closed={d}/{d} host_free={d} native={any} initializers={any}\n", .{ @tagName(mode), observer.downs, observer.ups, observer.completions, observer.masked, observer.borrowed, observer.restored, observer.a_detached, observer.a_closed, observer.b_closed, observer.host_frees, native, initializers });
    try std.testing.expectEqualDeep(web.ResourceCounts{ .states = 0, .handlers = 0, .controllers = 0 }, native);
    try std.testing.expectEqualDeep(web.InitializerNativeCounts{}, initializers);
    try std.testing.expect(observer.downs == 1 and observer.ups == 1 and observer.completions == 1 and observer.restored == 1 and observer.a_detached == 1 and observer.a_closed == 1 and observer.b_closed == 1 and observer.host_frees == 1);
    if (observer.failure) |err| return err;
    try std.testing.expect(observer.masked == 1 and observer.borrowed == 0);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();
    _ = args.next();
    const mode = std.meta.stringToEnum(Mode, args.next() orelse return error.ExpectedMode) orelse return error.InvalidMode;
    const profile = if (builtin.os.tag == .windows) args.next() orelse return error.ExpectedAbsoluteFixtureProfile else "";
    if (builtin.os.tag == .windows and !std.fs.path.isAbsolute(profile)) return error.ExpectedAbsoluteFixtureProfile;
    if (args.next() != null) return error.TooManyArguments;
    try scenario(gpa.allocator(), mode, profile);
}
