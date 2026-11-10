//! Windows: a window stays cloaked until its first frame painted, one whose
//! frames show through DirectComposition until DWM composed that frame, and
//! the session's end (WM_ENDSESSION) finishes the quit inside the
//! notification.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const exitAfter = @import("watchdog.zig").exitAfter;
const c = @import("ziggurat_c_win32");
extern "dwmapi" fn DwmGetWindowAttribute(c.HWND, u32, *anyopaque, u32) callconv(.winapi) c.HRESULT;
const dwm_cloaked = 14;

const Node = struct {
    requests: usize = 0,
    reason: ?z.CloseReason = null,
    closed: usize = 0,
    fn request(ptr: *anyopaque, _: z.Window, reason: z.CloseReason) z.CloseDecision {
        const self: *Node = @ptrCast(@alignCast(ptr));
        self.requests += 1;
        self.reason = reason;
        // The OS has decided: a veto is ignored.
        return .cancel;
    }
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const self: *Node = @ptrCast(@alignCast(ptr));
        self.closed += 1;
    }
};

fn cloaked(hwnd: c.HWND) bool {
    var value: u32 = 0;
    if (DwmGetWindowAttribute(hwnd, dwm_cloaked, &value, @sizeOf(u32)) < 0) return false;
    return value != 0;
}

/// The App's dispatcher: a hidden top-level window of this process.
fn dispatcher() ?c.HWND {
    var cursor: c.HWND = null;
    while (true) {
        cursor = c.FindWindowExW(null, cursor, std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat.Dispatch.0"), null) orelse return null;
        var pid: c.DWORD = 0;
        _ = c.GetWindowThreadProcessId(cursor, &pid);
        if (pid == c.GetCurrentProcessId()) return cursor;
    }
}

var revealed = std.atomic.Value(bool).init(false);

fn watch(hwnd: c.HWND, composed: c.HWND, target: c.HWND) void {
    // DWM's attributes read from any thread; the main thread only runs.
    for (0..500) |_| {
        if (!cloaked(hwnd) and !cloaked(composed)) {
            revealed.store(true, .release);
            break;
        }
        zio.sleep(10 * std.time.ns_per_ms);
    }
    _ = c.PostMessageW(target, c.WM_ENDSESSION, 1, 0);
}

pub fn main() !void {
    try exitAfter("smoke-window-reveal", 30);
    const app = try z.App.init(std.heap.page_allocator);
    defer app.deinit();
    var node: Node = .{};
    const window = try app.createWindow(.{ .title = "Reveal", .on_close = .{ .context = &node, .request = Node.request }, .on_closed = .{ .context = &node, .notify = Node.notify } });
    const hwnd: c.HWND = @ptrCast(window.nativeHandle().?);
    if (!cloaked(hwnd)) return error.NotCloakedBeforeFirstFrame;
    try window.perform(.show);
    // Its first WM_PAINT shows it at once: DWM shows the window's own
    // pixels until the frame presents.
    _ = c.UpdateWindow(hwnd);
    if (cloaked(hwnd)) return error.CloakedAfterFirstFrame;
    // A transparent window has no redirection bitmap: shown before DWM
    // composed its first frame, it would show black.
    const composed_window = try app.createWindow(.{ .title = "Composed", .transparent = true });
    const composed: c.HWND = @ptrCast(composed_window.nativeHandle().?);
    try composed_window.perform(.show);
    _ = c.UpdateWindow(composed);
    if (!cloaked(composed)) return error.ComposedShownBeforeDwm;
    const target = dispatcher() orelse return error.NoDispatcher;
    const thread = try std.Thread.spawn(.{}, watch, .{ hwnd, composed, target });
    try app.run();
    thread.join();
    if (!revealed.load(.acquire)) return error.StillCloaked;
    if (app.phase != .stopped) return error.NotStopped;
    if (node.requests != 1 or node.reason != .session_end) return error.CloseNotAsked;
    if (node.closed != 1) return error.NotClosed;
    std.debug.print("smoke-window-reveal: ok\n", .{});
}
