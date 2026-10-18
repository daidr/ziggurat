const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_free(?*anyopaque) void;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
extern fn gdk_display_get_default() *anyopaque;
extern fn gdk_keymap_get_for_display(*anyopaque) *anyopaque;
extern fn gdk_keymap_get_entries_for_keyval(*anyopaque, c_uint, *?[*]KeymapKey, *c_int) c_int;
extern fn g_setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern fn zlg_resource_count() u32;
const KeymapKey = extern struct { keycode: c_uint, group: c_int, level: c_int };
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };

const Probe = struct {
    window: z.Window = undefined,
    expected: ?z.KeyInput = null,
    keys: usize = 0,
    legacy: usize = 0,
    text: usize = 0,
    services: usize = 0,
    consumed_services: usize = 0,
    close_on_key: bool = false,
    closed: bool = false,
    compose: bool = false,
    pass_key: bool = false,
    fn event(ptr: *anyopaque, _: z.Window, value: z.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (value == .key or value == .edit_key) self.legacy += 1;
        if (value == .text_input) self.text += 1;
        std.debug.assert(value != .key_input);
    }
    fn key(ptr: *anyopaque, window: z.Window, input: z.KeyInput) bool {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.keys += 1;
        if (self.expected) |expected| std.debug.assert(std.meta.eql(expected, input));
        if (self.close_on_key) {
            std.debug.assert((window.destroy() catch unreachable) == .deferred);
            std.debug.assert(!self.closed);
            return false;
        }
        return !self.compose and !self.pass_key and input.key != .f5;
    }
    fn detach(_: *anyopaque) void {}
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
    fn service(ptr: *anyopaque, window: z.Window, message: u32, wp: usize, _: isize) ?isize {
        if (builtin.os.tag != .windows) return null;
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (message == c.WM_APP + 93) {
            window.app.quit();
            return 0;
        }
        if (message == c.WM_KEYDOWN or message == c.WM_SYSKEYDOWN) {
            if (wp == c.VK_F5) self.services += 1;
            if (wp == c.VK_F6) self.consumed_services += 1;
            return 0;
        }
        return null;
    }
    fn init(self: *Probe, app: *z.App) !void {
        self.window = try app.createWindow(.{ .on_closed = .{ .context = self, .notify = notify } });
        try self.window.setContent(.{ .context = self, .event = event, .detach = detach, .key_input = key });
    }
};

fn send(window: z.Window, code: u32, unshifted: u32, modifiers: z.KeyModifiers, repeat: bool, release: bool, altgr: bool) !void {
    if (builtin.os.tag == .windows) {
        var previous: [256]u8 = undefined;
        if (c.GetKeyboardState(&previous) == 0) return error.KeyboardStateUnavailable;
        defer _ = c.SetKeyboardState(&previous);
        var current: [256]u8 = @splat(0);
        current[c.VK_SHIFT] = if (modifiers.shift) 0x80 else 0;
        current[c.VK_CONTROL] = if (modifiers.control) 0x80 else 0;
        current[c.VK_MENU] = if (modifiers.alt) 0x80 else 0;
        current[c.VK_LWIN] = if (modifiers.super) 0x80 else 0;
        current[c.VK_RMENU] = if (altgr) 0x80 else 0;
        if (c.SetKeyboardState(&current) == 0) return error.KeyboardStateUnavailable;
        const kind: c.UINT = if (modifiers.alt) c.WM_SYSKEYDOWN else c.WM_KEYDOWN;
        _ = c.SendMessageW(window.nativeHandle(), kind, code, if (repeat) 1 << 30 else 0);
    } else {
        const area = gtk_bin_get_child(window.nativeHandle().?).?;
        var hardware: u16 = 0;
        var group: u8 = 0;
        if (unshifted != 0) {
            var entries: ?[*]KeymapKey = null;
            var count: c_int = 0;
            const map = gdk_keymap_get_for_display(gdk_display_get_default());
            if (gdk_keymap_get_entries_for_keyval(map, unshifted, &entries, &count) == 0) return error.KeymapEntryMissing;
            defer g_free(entries);
            for (entries.?[0..@intCast(count)]) |entry| if (entry.level == 0 and entry.keycode > 0 and entry.keycode < 1024 and entry.group >= 0 and entry.group <= 255) {
                hardware = @intCast(entry.keycode);
                group = @intCast(entry.group);
                break;
            };
            if (hardware == 0) return error.UnshiftedKeyMissing;
        }
        const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        const native: *KeyEvent = @ptrCast(@alignCast(event));
        native.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(area).?), .send_event = 1, .time = 0, .state = (if (modifiers.shift) @as(u32, 1) else 0) | (if (modifiers.control) @as(u32, 4) else 0) | (if (modifiers.alt) @as(u32, 8) else 0) | (if (modifiers.super) @as(u32, 1 << 26) else 0) | (if (altgr) @as(u32, 1 << 7) else 0), .keyval = code, .length = 0, .string = null, .hardware_keycode = hardware, .group = group, .modifier_storage = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(area, "key-press-event", native, &handled);
        if (release and !window.isClosed()) {
            native.kind = 9;
            g_signal_emit_by_name(area, "key-release-event", native, &handled);
        }
    }
}
fn check(probe: *Probe, expected: z.KeyInput, win_code: u32, keyval: u32, base: u32, release: bool) !void {
    probe.expected = expected;
    const before = probe.keys;
    try send(probe.window, if (builtin.os.tag == .windows) win_code else keyval, base, expected.modifiers, expected.repeat, release, false);
    try std.testing.expectEqual(before + 1, probe.keys);
    probe.expected = null;
}
fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{};
    try probe.init(app);
    try check(&probe, .{ .key = .digit1, .modifiers = .{ .shift = true } }, '1', '!', '1', true);
    try check(&probe, .{ .key = .a, .modifiers = .{ .shift = true } }, 'A', 'A', 'a', true);
    if (builtin.os.tag == .windows) {
        if (c.MapVirtualKeyExW(c.VK_OEM_1, c.MAPVK_VK_TO_CHAR, c.GetKeyboardLayout(0)) == ';') try check(&probe, .{ .key = .semicolon, .modifiers = .{ .shift = true } }, c.VK_OEM_1, ':', ';', true);
    } else try check(&probe, .{ .key = .semicolon, .modifiers = .{ .shift = true } }, 0, ':', ';', true);
    try check(&probe, .{ .key = .f24, .modifiers = .{ .control = true, .alt = true, .super = true } }, 0x87, 0xffd5, 0, true);
    try check(&probe, .{ .key = .a }, 'A', 'a', 'a', false);
    try check(&probe, .{ .key = .a, .repeat = true }, 'A', 'a', 'a', true);
    try check(&probe, .{ .key = .a }, 'A', 'a', 'a', true);
    const before_altgr = probe.keys;
    const text_before_altgr = probe.text;
    try send(probe.window, if (builtin.os.tag == .windows) 'Q' else '@', 'q', .{ .control = true, .alt = true }, false, true, true);
    try std.testing.expectEqual(before_altgr, probe.keys);
    if (builtin.os.tag == .linux) try std.testing.expectEqual(text_before_altgr + 1, probe.text);
    probe.pass_key = true;
    const before_modifiers = probe.text;
    try check(&probe, .{ .key = .left, .modifiers = .{ .alt = true } }, 0x25, 0xff51, 0, true);
    try check(&probe, .{ .key = .left, .modifiers = .{ .super = true } }, 0x25, 0xff51, 0, true);
    try check(&probe, .{ .key = .a, .modifiers = .{ .alt = true } }, 'A', 'a', 'a', true);
    try check(&probe, .{ .key = .a, .modifiers = .{ .super = true } }, 'A', 'a', 'a', true);
    try std.testing.expectEqual(before_modifiers, probe.text);
    probe.pass_key = false;
    if (builtin.os.tag == .windows) {
        _ = c.SendMessageW(probe.window.nativeHandle(), c.WM_IME_STARTCOMPOSITION, 0, 0);
        const keys_before = probe.keys;
        const legacy_before = probe.legacy;
        try send(probe.window, c.VK_LEFT, 0, .{}, false, true, false);
        try send(probe.window, c.VK_RETURN, 0, .{}, false, true, false);
        try std.testing.expectEqual(keys_before, probe.keys);
        try std.testing.expectEqual(legacy_before, probe.legacy);
        _ = c.SendMessageW(probe.window.nativeHandle(), c.WM_IME_ENDCOMPOSITION, 0, 0);
    } else {
        probe.compose = true;
        try send(probe.window, 0xff20, 0, .{}, false, true, false);
        const keys_before = probe.keys;
        const text_before = probe.text;
        try send(probe.window, '\'', 0, .{}, false, true, false);
        try send(probe.window, 'e', 0, .{}, false, true, false);
        try std.testing.expectEqual(keys_before, probe.keys);
        try std.testing.expectEqual(text_before + 1, probe.text);
        probe.compose = false;
    }
    try std.testing.expectEqual(@as(usize, 0), probe.legacy);
    probe.close_on_key = true;
    try check(&probe, .{ .key = .f4 }, 0x73, 0xffc1, 0, false);
    try std.testing.expect(!probe.closed);
    try app.dispatch();
    try std.testing.expect(probe.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
fn runQueue(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{};
    try probe.init(app);
    try probe.window.setService(.{ .context = &probe, .message = Probe.service, .native_destroying = Probe.detach });
    try check(&probe, .{ .key = .f5 }, c.VK_F5, 0, 0, true);
    try check(&probe, .{ .key = .f6 }, c.VK_F6, 0, 0, true);
    try std.testing.expectEqual(@as(usize, 1), probe.services);
    try std.testing.expectEqual(@as(usize, 0), probe.consumed_services);
    const foreign = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), null, 0, 0, 0, 10, 10, null, null, c.GetModuleHandleW(null), null);
    if (foreign == null) return error.ForeignWindowCreateFailed;
    defer _ = c.DestroyWindow(foreign);
    _ = c.SetWindowLongPtrW(foreign, c.GWLP_USERDATA, 1);
    if (c.PostMessageW(foreign, c.WM_KEYDOWN, 'Q', 0) == 0) return error.PostFailed;
    const hwnd: c.HWND = probe.window.nativeHandle();
    if (c.PostMessageW(hwnd, c.WM_KEYDOWN, c.VK_F5, 0) == 0 or c.PostMessageW(hwnd, c.WM_KEYDOWN, c.VK_F6, 0) == 0 or c.PostMessageW(hwnd, c.WM_APP + 93, 0, 0) == 0) return error.PostFailed;
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    try std.testing.expect(!watchdog.expired);
    try std.testing.expectEqual(@as(usize, 4), probe.keys);
    try std.testing.expectEqual(@as(usize, 2), probe.services);
    try std.testing.expectEqual(@as(usize, 0), probe.consumed_services);
}
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    if (builtin.os.tag == .linux) _ = g_setenv("GTK_IM_MODULE", "simple", 1);
    try run(allocator.allocator());
    try runQueue(allocator.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("key input passed: logical shifted keys, modifiers, repeat, AltGr/IME ownership, native queue/direct priority, foreign HWND and callback close; resources=0\n", .{});
}
