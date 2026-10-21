const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const term = @import("ziggurat_terminal");
const terminal_view = @import("ziggurat_terminal_view");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};

extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };

const width = 640;
const height = 400;

const Native = struct {
    fn paint(window: z.Window) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            _ = c.InvalidateRect(hwnd, null, 0);
            _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
        } else {
            const scope = window.beginCallback().?;
            defer scope.end();
            zlg_test_paint(scope.record.native.native.?, width, height);
        }
    }
    fn pointer(window: z.Window, down: bool, x: f32, y: f32) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
            const px: u16 = @bitCast(@as(i16, @intFromFloat(x * scale)));
            const py: u16 = @bitCast(@as(i16, @intFromFloat(y * scale)));
            const point: c.LPARAM = @intCast(@as(u32, px) | (@as(u32, py) << 16));
            _ = c.SendMessageW(hwnd, if (down) c.WM_LBUTTONDOWN else c.WM_LBUTTONUP, if (down) c.MK_LBUTTON else 0, point);
        } else {
            const widget = gtk_bin_get_child(window.nativeHandle().?).?;
            const event = gdk_event_new(if (down) 4 else 7).?;
            defer gdk_event_free(event);
            const native: *ButtonEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = if (down) 4 else 7, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = if (down) 0 else 1 << 8, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, if (down) @as([*:0]const u8, "button-press-event") else @as([*:0]const u8, "button-release-event"), native, &handled);
        }
    }
    fn click(window: z.Window, bounds: view.Rect) void {
        const x = bounds.x + bounds.width / 2;
        const y = bounds.y + bounds.height / 2;
        pointer(window, true, x, y);
        pointer(window, false, x, y);
    }
    /// Press Enter through the platform's key path.
    fn enter(window: z.Window) !void {
        if (builtin.os.tag == .windows) {
            _ = c.SendMessageW(window.nativeHandle(), c.WM_KEYDOWN, c.VK_RETURN, 0);
        } else {
            const widget = gtk_bin_get_child(window.nativeHandle().?).?;
            const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const native: *KeyEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .state = 0, .keyval = 0xff0d, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "key-press-event", native, &handled);
            try std.testing.expect(handled != 0);
        }
    }
    /// Type through the platform's text path.
    fn commit(window: z.Window, value: [:0]const u8) !void {
        if (builtin.os.tag == .linux) {
            zlg_test_commit(window.app.windows.get(window.key).?.native.native.?, value);
        } else {
            const token = window.textClientToken() orelse return error.NoTextClient;
            var current: [64]u8 = undefined;
            const snapshot = try window.readTextClient(token, &current);
            _ = try window.changeTextClient(token, .{ .replace = .{ .range = .{ .start = snapshot.selection.caret, .end = snapshot.selection.caret }, .text = value } });
        }
    }
};

const State = struct {
    terminal: *terminal_view.TerminalView = undefined,
    fn build(self: *State, v: *view.View) anyerror!void {
        try v.text("Shell", .{ .key = 1 });
        try v.embed(self.terminal.embed(), .{ .grow = 1, .self_align = .stretch, .key = 2 });
    }
};

fn find(host: *const view.Host, kind: view.Kind) !view.Node {
    for (host.view.nodes()) |node| if (node.kind == kind) return node;
    return error.MissingNode;
}

fn paint(host: *view.Host, window: z.Window) !void {
    const before = host.frames;
    Native.paint(window);
    if (host.last_error) |err| return err;
    try std.testing.expectEqual(before + 1, host.frames);
}

/// Whether any row of the screen contains `needle`.
fn shows(screen: *const term.Screen, needle: []const u8) bool {
    var line: [512]u8 = undefined;
    for (0..screen.rows) |y| {
        var len: usize = 0;
        for (screen.row(@intCast(y))) |cell| {
            if (cell.wide == .spacer or len + 4 > line.len) continue;
            len += std.unicode.utf8Encode(if (cell.cp == 0) ' ' else cell.cp, line[len..]) catch continue;
        }
        if (std.mem.indexOf(u8, line[0..len], needle) != null) return true;
    }
    return false;
}

/// Dispatch posted work until `done` or a deadline.
fn until(app: *z.App, context: anytype, comptime done: fn (@TypeOf(context)) bool) !void {
    const deadline = std.time.milliTimestamp() + 10_000;
    while (!done(context)) {
        if (std.time.milliTimestamp() > deadline) return error.Timeout;
        try app.dispatch();
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
}

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    var storage: view.Storage(16, 512) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    try host.context.prepareTextFields(allocator, .{});

    var terminal = try term.Terminal.init(allocator, .{});
    defer terminal.deinit();
    var tv = terminal_view.TerminalView.init(&host, allocator, &terminal, .{});
    defer tv.deinit();
    tv.bind();
    state.terminal = &tv;

    // The first frame places the leaf; the grid takes its size and the
    // leaf registers for input after it.
    try paint(&host, window);
    try std.testing.expect(tv.queued);
    try app.dispatch();
    if (tv.last_error) |err| return err;
    try std.testing.expect(tv.token != null);
    const grid = tv.applied.?;
    try std.testing.expectEqual(grid.cols, terminal.screen.cols);
    try std.testing.expectEqual(grid.rows, terminal.screen.rows);
    try std.testing.expect(grid.cols > 40 and grid.rows > 10);
    // An unchanged terminal paints without posting.
    try paint(&host, window);
    try paint(&host, window);
    try std.testing.expect(!tv.queued);

    // A shell in the grid's size, answering what is typed.
    const argv: []const []const u8 = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/q", "/k", "prompt $G" } else &.{ "/bin/sh", "-i" };
    const env: []const term.pty.Variable = if (builtin.os.tag == .windows) &.{} else &.{ .{ .name = "PS1", .value = "$ " }, .{ .name = "ENV", .value = "" } };
    const session = try term.Session.spawn(allocator, app, .{ .argv = argv, .env = env, .size = grid }, tv.sink(), .{});
    var closed = false;
    defer if (!closed) session.close();
    tv.attachSession(session);

    const box = try find(&host, .embed);
    Native.click(window, box.bounds);
    try std.testing.expectEqual(@as(?u64, box.id), host.context.input_state.focused);
    try std.testing.expect(try window.hasTextClient());
    // The typed line itself never shows the answer, only the shell's output.
    if (builtin.os.tag == .windows) {
        try Native.commit(window, "set Z=42");
        try Native.enter(window);
        try Native.commit(window, "echo zig%Z%gurat");
    } else try Native.commit(window, "echo zig$((6*7))gurat");
    try Native.enter(window);
    try until(app, &terminal.screen, struct {
        fn done(screen: *term.Screen) bool {
            return shows(screen, "zig42gurat");
        }
    }.done);
    if (tv.last_error) |err| return err;
    try paint(&host, window);

    // The program learns the size the grid takes.
    if (builtin.os.tag != .windows) {
        try Native.commit(window, "stty size");
        try Native.enter(window);
        var expected: [32]u8 = undefined;
        const size = try std.fmt.bufPrint(&expected, "{d} {d}", .{ grid.rows, grid.cols });
        const Wait = struct { screen: *term.Screen, text: []const u8 };
        try until(app, Wait{ .screen = &terminal.screen, .text = size }, struct {
            fn done(wait: Wait) bool {
                return shows(wait.screen, wait.text);
            }
        }.done);
    }

    // Selecting everything reads the echoed output back.
    tv.selectAll();
    const all = (try tv.selectedText(allocator)).?;
    defer allocator.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "zig42gurat") != null);

    // Leaving the shell reports its exit once.
    try Native.commit(window, "exit");
    try Native.enter(window);
    try until(app, &tv, struct {
        fn done(v: *terminal_view.TerminalView) bool {
            return v.exit != null;
        }
    }.done);
    try paint(&host, window);
    session.close();
    closed = true;
    // The workers finish on their own and free the session.
    try until(app, {}, struct {
        fn done(_: void) bool {
            return term.liveSessions() == 0;
        }
    }.done);

    tv.detach();
    _ = try window.destroy();
    try app.dispatch();
    try std.testing.expect(host.context.window == null);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("terminal native: grid sizing, shell echo through the text path, resize report, selection and exit passed\n", .{});
}
