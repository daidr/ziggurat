//! A web view between two buttons of native UI on Windows, its page
//! composed under the window's frames. The window sends the page the
//! pointer where it shows, and keeps it where the native UI paints over
//! the page: a popover opened over the page takes that part of the window
//! back from it. Tab moves the keyboard from the first button into the page
//! at its first element, through it, and on to the last button; Shift+Tab
//! comes back into the page at its last element. With accessibility, a UI
//! Automation client finds the page's document in the window's tree.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const web = @import("ziggurat_webview");
const embedded = @import("ziggurat_webview_view");
const zio = @import("ziggurat_io");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @import("ziggurat_c_win32");

const Phase = enum { loading, clicked, first, into, through, out, back, covered, tree, done };
var active: ?*State = null;

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
    /// Presses the page heard, and the y of the last, in its CSS pixels.
    downs: u32 = 0,
    down_y: i32 = -1,
    /// The UI Automation client's verdict, set by its thread.
    tree: std.atomic.Value(i32) = .init(0),
    client: ?std.Thread = null,
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
        std.debug.print("windows web view overlay {s}: {s}\n", .{ @tagName(self.phase), @errorName(err) });
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
            } else if (std.mem.startsWith(u8, text, "down:")) {
                self.downs += 1;
                self.down_y = std.fmt.parseInt(i32, text["down:".len..], 10) catch -1;
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
    fn windowsTick(_: c.HWND, _: c.UINT, _: c.UINT_PTR, _: c.DWORD) callconv(.winapi) void {
        const self = active orelse return;
        if (self.phase == .done or self.failure != null) return;
        self.step() catch |err| self.fail(err);
    }
    fn hwnd(self: *State) c.HWND {
        return @ptrCast(self.window.nativeHandle());
    }
    fn paint(self: *State) void {
        _ = c.InvalidateRect(self.hwnd(), null, 0);
        _ = c.SendMessageW(self.hwnd(), c.WM_PAINT, 0, 0);
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
    /// A click of the window's client area at x, y DIPs, as the mouse
    /// sends it.
    fn click(self: *State, x: f32, y: f32) void {
        const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(self.hwnd()))) / 96.0;
        const px: u32 = @intFromFloat(@round(x * scale));
        const py: u32 = @intFromFloat(@round(y * scale));
        const at: c.LPARAM = @intCast(px | (py << 16));
        _ = c.SendMessageW(self.hwnd(), c.WM_MOUSEMOVE, 0, at);
        _ = c.SendMessageW(self.hwnd(), c.WM_LBUTTONDOWN, c.MK_LBUTTON, at);
        _ = c.SendMessageW(self.hwnd(), c.WM_LBUTTONUP, 0, at);
    }
    /// Tab, or Shift+Tab, as the keyboard sends it to the window that has
    /// the keyboard, which the page's own window is while it has it.
    fn press(self: *State, shift: bool) !void {
        _ = c.SetForegroundWindow(self.hwnd());
        var inputs: [4]c.INPUT = @splat(std.mem.zeroes(c.INPUT));
        var count: usize = 0;
        const keys = if (shift) [_]u16{ c.VK_SHIFT, c.VK_TAB } else [_]u16{ c.VK_TAB, 0 };
        for (keys) |key| if (key != 0) {
            inputs[count].type = c.INPUT_KEYBOARD;
            inputs[count].unnamed_0.ki.wVk = key;
            count += 1;
        };
        var index = count;
        while (index > 0) {
            index -= 1;
            inputs[count] = inputs[index];
            inputs[count].unnamed_0.ki.dwFlags = c.KEYEVENTF_KEYUP;
            count += 1;
        }
        if (c.SendInput(@intCast(count), &inputs, @sizeOf(c.INPUT)) != count) return error.InputRefused;
    }
    fn step(self: *State) !void {
        if (self.host.last_error) |err| return err;
        if (self.web_views.takeError()) |err| return err;
        self.ticks += 1;
        self.paint();
        const state = &self.host.context.input_state;
        if (self.ticks > self.since + 500) {
            std.debug.print("page keyboard={} element={s} downs={d} control={?d} wanted={?d}\n", .{ self.page.holdsKeyboard(), self.focused[0..self.focused_len], self.downs, state.focused, self.control(2) });
            return error.TimedOut;
        }
        switch (self.phase) {
            .loading => {
                const snapshot = try self.item.region.?.snapshot();
                if (!self.loaded or !snapshot.viewport.visible or self.ticks < 10) return;
                if (self.page.accessibleNative() == null) return error.NoAutomationProvider;
                const box = self.leaf() orelse return error.NoLeaf;
                // A press on the page goes to it, and gives it the keyboard.
                self.click(box.x + box.width / 2, box.y + box.height - 20);
                self.next(.clicked);
            },
            .clicked => {
                if (self.downs == 0 or !self.page.holdsKeyboard()) return;
                // The keyboard back with the window, from the first button.
                _ = c.SetFocus(self.hwnd());
                self.host.context.blurControls() catch {};
                self.focused_len = 0;
                try self.press(false);
                self.next(.first);
            },
            .first => {
                if (state.focused == null or self.page.holdsKeyboard()) return;
                if (state.focused != self.control(0)) return error.WrongFirstFocus;
                try self.press(false);
                self.next(.into);
            },
            .into => {
                if (!self.pageFocused("a") or !self.page.holdsKeyboard()) return;
                try self.press(false);
                self.next(.through);
            },
            .through => {
                if (!self.pageFocused("b")) return;
                try self.press(false);
                self.next(.out);
            },
            .out => {
                if (self.page.holdsKeyboard() or state.focused != self.control(2)) return;
                self.focused_len = 0;
                try self.press(true);
                self.next(.back);
            },
            .back => {
                if (!self.pageFocused("b") or !self.page.holdsKeyboard()) return;
                self.popover = true;
                self.window.invalidate();
                self.downs = 0;
                self.next(.covered);
            },
            .covered => {
                if (self.ticks < self.since + 10) return;
                const box = self.leaf() orelse return error.NoLeaf;
                if (self.downs == 0) {
                    if (self.ticks == self.since + 10) {
                        // The popover under the first button, over the
                        // page's top, takes the press there; the page takes
                        // the one below it.
                        self.click(box.x + 20, box.y + 20);
                        self.click(box.x + 20, box.y + box.height - 10);
                    }
                    return;
                }
                if (self.ticks < self.since + 30) return;
                if (self.downs != 1) return error.PageTookCoveredPress;
                if (@as(f32, @floatFromInt(self.down_y)) < box.height / 2) return error.PageTookCoveredPress;
                if (!ui.capabilities.accessibility) {
                    self.next(.done);
                    self.app.quit();
                    return;
                }
                self.client = try std.Thread.spawn(.{}, findDocument, .{ self, self.hwnd() });
                self.next(.tree);
            },
            .tree => switch (self.tree.load(.acquire)) {
                0 => {},
                1 => {
                    self.next(.done);
                    self.app.quit();
                },
                else => return error.PageNotInTree,
            },
            .done => {},
        }
    }
};

/// A UI Automation client on its own thread: the window's tree holds the
/// page's document, once.
fn findDocument(self: *State, hwnd: c.HWND) void {
    const found = documents(hwnd) catch |err| blk: {
        std.debug.print("page tree: {s}\n", .{@errorName(err)});
        break :blk -1;
    };
    self.tree.store(if (found == 1) 1 else -1, .release);
    if (found != 1) std.debug.print("page documents in the tree: {d}\n", .{found});
}
fn release(object: anytype) void {
    _ = object.lpVtbl.*.Release.?(object);
}
fn documents(hwnd: c.HWND) !i32 {
    if (c.CoInitializeEx(null, c.COINIT_MULTITHREADED) < 0) return error.ComInitFailed;
    defer c.CoUninitialize();
    var automation: ?*c.IUIAutomation = null;
    if (c.CoCreateInstance(&c.CLSID_CUIAutomation, null, c.CLSCTX_INPROC_SERVER, &c.IID_IUIAutomation, @ptrCast(&automation)) < 0) return error.NoAutomation;
    defer release(automation.?);
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        var root: ?*c.IUIAutomationElement = null;
        if (automation.?.lpVtbl.*.ElementFromHandle.?(automation.?, hwnd, &root) < 0 or root == null) return error.NoRoot;
        defer release(root.?);
        var kind: c.VARIANT = std.mem.zeroes(c.VARIANT);
        kind.unnamed_0.unnamed_0.vt = c.VT_I4;
        kind.unnamed_0.unnamed_0.unnamed_0.lVal = c.UIA_DocumentControlTypeId;
        var condition: ?*c.IUIAutomationCondition = null;
        if (automation.?.lpVtbl.*.CreatePropertyCondition.?(automation.?, c.UIA_ControlTypePropertyId, kind, &condition) < 0) return error.NoCondition;
        defer release(condition.?);
        var all: ?*c.IUIAutomationElementArray = null;
        if (root.?.lpVtbl.*.FindAll.?(root.?, c.TreeScope_Descendants, condition, &all) < 0 or all == null) return error.FindFailed;
        defer release(all.?);
        var length: c_int = 0;
        _ = all.?.lpVtbl.*.get_Length.?(all.?, &length);
        if (length > 0) return length;
        c.Sleep(100);
    }
    return 0;
}

const document =
    \\<!doctype html><body style="margin:0;height:100vh"><input id=a><input id=b>
    \\<script>addEventListener('focusin',e=>chrome.webview.postMessage('focus:'+e.target.id));
    \\addEventListener('mousedown',e=>chrome.webview.postMessage('down:'+Math.round(e.clientY)))</script>
;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    // WebView2 keeps its profile in an absolute folder.
    var temporary = zio.tmpDir(.{});
    defer temporary.cleanup();
    var profile: ?[]u8 = null;
    defer if (profile) |path| allocator.free(path);
    const Prepare = struct {
        fn run(dir: std.Io.Dir, gpa_allocator: std.mem.Allocator, out: *?[]u8) void {
            out.* = zio.realPathAlloc(dir, ".", gpa_allocator) catch null;
        }
    };
    const worker = try std.Thread.spawn(.{}, Prepare.run, .{ temporary.dir, allocator, &profile });
    worker.join();
    if (profile == null) return error.ProfileUnavailable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app };
    var storage: view.Storage(32, 256) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0), .alignment = .stretch } });
    host.context.render_mode = .gdi;
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
    try web_views.add(&state.item, &state.page, .{ .html = document, .storage = .profile, .user_data_folder = profile.?, .page_listener = .{ .context = &state, .event = State.pageEvent } });
    state.window.show();
    active = &state;
    defer active = null;
    const timer = c.SetTimer(null, 0, 20, @ptrCast(&State.windowsTick));
    if (timer == 0) return error.CreateTimerFailed;
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.client) |thread| thread.join();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.phase == .done);
    state.item.remove();
    _ = try state.window.destroy();
    std.debug.print("windows web view overlay: the page took the pointer and the keyboard where it shows, and the popover over it took the press there; Tab went into the page, through it and out, Shift+Tab back to its last element{s}\n", .{if (ui.capabilities.accessibility) "; the page's document is in the window's tree" else ""});
}
