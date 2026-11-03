//! A web view between two buttons of native UI in a macOS window. The
//! native UI shows over the page where it paints after it: a popover opened
//! over the page masks that part of the page and takes the pointer there.
//! Tab moves the keyboard from the first button into the page at its first
//! element, through it, and on to the last button; Shift+Tab comes back
//! into the page at its last element. With accessibility, the page's tree
//! is inside the web view's node of the native UI's.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const web = @import("ziggurat_webview");
const embedded = @import("ziggurat_webview_view");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
extern fn zwk_test_page_at(*anyopaque, i32, i32) c_int;
extern fn zwk_has_focus(*anyopaque) c_int;
extern fn zwo_timer(c_uint, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) void;
extern fn zwo_activate(*anyopaque) c_int;
extern fn zwo_tab(*anyopaque, c_int) c_int;
extern fn zwo_scale(*anyopaque) f64;
extern fn zua_test_page_in_tree(*anyopaque) c_int;

const Phase = enum { loading, shaped, first, into, through, out, back, covered, done };

const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    host: *view.Host = undefined,
    web_views: *embedded.WebViews = undefined,
    item: embedded.WebView = undefined,
    page: web.View = undefined,
    loaded: bool = false,
    popover: bool = false,
    phase: Phase = .loading,
    ticks: u32 = 0,
    since: u32 = 0,
    /// The last element of the page that took the focus.
    focused: [8]u8 = undefined,
    focused_len: usize = 0,
    failure: ?anyerror = null,

    fn build(self: *State, v: *view.View) !void {
        try v.column(.{ .grow = 1, .alignment = .stretch, .gap = 0, .padding = view.Insets.all(0) });
        _ = try v.button("Before", .{ .height = 30 });
        if (try v.popover(&self.popover, .{}, .{ .name = "Over the page" })) {
            _ = try v.button("Inside", .{ .width = 120, .height = 60 });
        }
        try v.end();
        try self.item.show(v, .{ .grow = 1 });
        _ = try v.button("After", .{ .height = 30 });
        try v.end();
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("macOS web view overlay {s}: {s}\n", .{ @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (input) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            .message => |text| if (std.mem.startsWith(u8, text, "focus:")) {
                const name = text["focus:".len..];
                self.focused_len = @min(name.len, self.focused.len);
                @memcpy(self.focused[0..self.focused_len], name[0..self.focused_len]);
            },
            else => {},
        }
    }
    fn pageEvent(ptr: *anyopaque, _: *web.View, input: web.PageEvent) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (input != .completed) return;
        if (!input.completed.success) return self.fail(error.LoadFailed);
        self.loaded = true;
    }
    fn tick(ptr: *anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.failure != null) return 0;
        self.step() catch |err| {
            self.fail(err);
            return 0;
        };
        return @intFromBool(self.phase != .done);
    }
    fn leaf(self: *State) ?view.Rect {
        for (self.host.view.nodes()) |node| if (node.kind == .embed) return node.bounds;
        return null;
    }
    /// The id of the control at `index` among the focusable ones.
    fn control(self: *State, index: usize) ?u64 {
        const state = &self.host.context.input_state;
        var seen: usize = 0;
        for (state.hits[0..state.len]) |hit| if (hit.options.enabled and hit.options.focusable) {
            if (seen == index) return hit.id;
            seen += 1;
        };
        return null;
    }
    fn pageFocused(self: *State, name: []const u8) bool {
        return std.mem.eql(u8, self.focused[0..self.focused_len], name);
    }
    fn next(self: *State, phase: Phase) void {
        self.phase = phase;
        self.since = self.ticks;
    }
    fn press(self: *State, shift: bool) !void {
        if (zwo_tab(self.window.nativeHandle().?, @intFromBool(shift)) == 0) return error.NoWindow;
    }
    /// Whether the page shows and takes the pointer at a point of the
    /// window, in its DIPs; else the native UI does.
    fn pageAt(self: *State, x: f32, y: f32) !bool {
        const scale = zwo_scale(self.window.nativeHandle().?);
        const value = zwk_test_page_at(self.page.native orelse return error.PageClosed, @intFromFloat(x * scale), @intFromFloat(y * scale));
        if (value < 0) return error.PageClosed;
        return value == 1;
    }
    fn pageHasKeyboard(self: *State) bool {
        const native = self.page.native orelse return false;
        return zwk_has_focus(native) != 0;
    }
    fn step(self: *State) !void {
        if (self.host.last_error) |err| return err;
        if (self.web_views.takeError()) |err| return err;
        self.ticks += 1;
        const native = self.window.nativeHandle().?;
        const state = &self.host.context.input_state;
        if (self.ticks > self.since + 400) {
            std.debug.print("page keyboard={} element={s} control={?d} wanted={?d}\n", .{ self.pageHasKeyboard(), self.focused[0..self.focused_len], state.focused, self.control(2) });
            return error.TimedOut;
        }
        switch (self.phase) {
            .loading => {
                const snapshot = try self.item.region.?.snapshot();
                if (!self.loaded or !snapshot.viewport.visible or self.ticks < 10) return;
                // A page focuses its elements and gives the keyboard back
                // by Tab only in the key window.
                if (zwo_activate(native) == 0) return;
                const box = self.leaf() orelse return error.NoLeaf;
                // The page shows in its leaf, the native UI around it.
                if (!try self.pageAt(box.x + box.width / 2, box.y + box.height / 2)) return;
                if (try self.pageAt(box.x + box.width / 2, 10)) return error.NativeUiHidden;
                self.next(.shaped);
            },
            .shaped => {
                if (ui.capabilities.accessibility) {
                    const found = zua_test_page_in_tree(native);
                    if (found < 0) {
                        std.debug.print("page in tree: {d}\n", .{found});
                        return error.PageNotInTree;
                    }
                    if (found == 0) return;
                }
                // Tab to the first button, as the window starts without a
                // focused control.
                try self.press(false);
                self.next(.first);
            },
            .first => {
                if (state.focused == null) return;
                if (state.focused != self.control(0)) return error.WrongFirstFocus;
                try self.press(false);
                self.next(.into);
            },
            .into => {
                if (!self.pageFocused("a") or !self.pageHasKeyboard()) return;
                try self.press(false);
                self.next(.through);
            },
            .through => {
                if (!self.pageFocused("b")) return;
                try self.press(false);
                self.next(.out);
            },
            .out => {
                if (self.pageHasKeyboard() or state.focused != self.control(2)) return;
                self.focused_len = 0;
                try self.press(true);
                self.next(.back);
            },
            .back => {
                if (!self.pageFocused("b") or !self.pageHasKeyboard()) return;
                self.popover = true;
                self.window.invalidate();
                self.next(.covered);
            },
            .covered => {
                const box = self.leaf() orelse return error.NoLeaf;
                // The popover under the first button, over the page's top.
                if (try self.pageAt(box.x + 20, box.y + 20)) return;
                if (!try self.pageAt(box.x + 20, box.y + box.height - 10)) return error.PageCovered;
                self.next(.done);
                self.app.quit();
            },
            .done => {},
        }
    }
};

const document =
    \\<!doctype html><input id=a><input id=b>
    \\<script>addEventListener('focusin',e=>chrome.webview.postMessage('focus:'+e.target.id))</script>
;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(@import("macos_panic.zig").allocator_config) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app };
    var storage: view.Storage(32, 256) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0), .alignment = .stretch } });
    state.host = &host;
    state.window = try app.createWindow(.{ .width = 360, .height = 300 });
    defer _ = state.window.destroy() catch {};
    const owner = try z.composition.Owner.create(allocator, state.window, .{ .capacity = 4 });
    defer owner.close() catch {};
    var web_views = embedded.WebViews.init(&host, owner);
    state.web_views = &web_views;
    host.options.after_frame = web_views.hook();
    _ = try host.attachBackdrop(owner);
    state.page = web.View.init(allocator, &state, State.event);
    try web_views.add(&state.item, &state.page, .{ .html = document, .storage = .ephemeral, .page_listener = .{ .context = &state, .event = State.pageEvent } });
    // Removing it again does nothing, so an error leaves no page behind.
    defer state.item.remove();
    state.window.show();
    zwo_timer(20, State.tick, &state);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.phase == .done);
    state.item.remove();
    _ = try state.window.destroy();
    std.debug.print("macOS web view overlay: the native UI showed around the page and its popover over it; Tab went into the page, through it and out, Shift+Tab back to its last element{s}\n", .{if (ui.capabilities.accessibility) "; the page's tree is inside the web view's node" else ""});
}
