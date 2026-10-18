const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const m = @import("model.zig");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
const NativeRect = extern struct { x: i32, y: i32, width: u32, height: u32 };
const NativeMonitor = extern struct { bounds: NativeRect, work: NativeRect, key: [96]u8, key_length: u32, primary: u32 };
extern fn zwp_query(*anyopaque, [*]NativeMonitor, u32, *u32) c_int;
extern fn zwp_metrics(*anyopaque, *[96]u8, *u32, *[4]u32, *NativeRect, *NativeRect) c_int;
fn check(value: c_int) !void {
    return switch (value) {
        0 => {},
        1 => error.UnsupportedCapability,
        3 => error.CapacityExceeded,
        else => error.DisplayQueryFailed,
    };
}
fn failed(window: z.Window) error{DisplayQueryFailed} {
    window.report(.{ .domain = .win32, .operation = .window_update, .code = c.GetLastError(), .err = error.DisplayQueryFailed });
    return error.DisplayQueryFailed;
}
fn rect(value: c.RECT) !m.Rect {
    if (value.right <= value.left or value.bottom <= value.top) return error.InvalidRectangle;
    return .{ .x = value.left, .y = value.top, .width = @intCast(@as(i64, value.right) - value.left), .height = @intCast(@as(i64, value.bottom) - value.top) };
}
const Enumeration = struct {
    monitors: [m.max_monitors]m.Monitor = undefined,
    count: usize = 0,
    err: ?anyerror = null,
    code: u32 = 0,
    fn visit(handle: c.HMONITOR, _: c.HDC, _: ?*c.RECT, context: c.LPARAM) callconv(.winapi) c.BOOL {
        const self: *@This() = @ptrFromInt(@as(usize, @bitCast(context)));
        self.one(handle) catch |err| {
            self.err = err;
            self.code = c.GetLastError();
            return 0;
        };
        return 1;
    }
    fn one(self: *@This(), handle: c.HMONITOR) !void {
        if (self.count == self.monitors.len) return error.CapacityExceeded;
        var info = std.mem.zeroes(c.MONITORINFOEXW);
        info.unnamed_0.cbSize = @sizeOf(c.MONITORINFOEXW);
        if (c.GetMonitorInfoW(handle, @ptrCast(&info)) == 0) return error.DisplayQueryFailed;
        var name: [96]u8 = undefined;
        const length = try std.unicode.utf16LeToUtf8(&name, std.mem.sliceTo(&info.szDevice, 0));
        self.monitors[self.count] = .{ .key = try m.Key.init(name[0..length]), .bounds = try rect(info.unnamed_0.rcMonitor), .work = try rect(info.unnamed_0.rcWork), .primary = info.unnamed_0.dwFlags & c.MONITORINFOF_PRIMARY != 0 };
        self.count += 1;
    }
};
pub fn query(window: z.Window) !m.Topology {
    if (builtin.os.tag == .windows) {
        var enumeration: Enumeration = .{};
        if (c.EnumDisplayMonitors(null, null, Enumeration.visit, @bitCast(@intFromPtr(&enumeration))) == 0) {
            if (enumeration.err) |err| {
                if (err == error.DisplayQueryFailed) window.report(.{ .domain = .win32, .operation = .window_update, .code = enumeration.code, .err = err });
                return err;
            }
            return failed(window);
        }
        return m.Topology.init(.win32_physical, enumeration.monitors[0..enumeration.count]);
    } else if (builtin.os.tag == .linux) {
        var native: [m.max_monitors]NativeMonitor = undefined;
        var count: u32 = 0;
        try check(zwp_query(window.nativeHandle().?, &native, native.len, &count));
        var monitors: [m.max_monitors]m.Monitor = undefined;
        for (native[0..count], 0..) |source, at| monitors[at] = .{ .key = try m.Key.init(source.key[0..source.key_length]), .bounds = .{ .x = source.bounds.x, .y = source.bounds.y, .width = source.bounds.width, .height = source.bounds.height }, .work = .{ .x = source.work.x, .y = source.work.y, .width = source.work.width, .height = source.work.height }, .primary = source.primary != 0 };
        return m.Topology.init(.x11_logical, monitors[0..count]);
    } else return error.UnsupportedCapability;
}
pub const Current = struct { key: m.Key, metrics: m.Metrics, observed: m.Bounds, frame: m.Rect };
pub fn current(window: z.Window) !Current {
    if (builtin.os.tag == .windows) {
        const hwnd: c.HWND = @ptrCast(window.nativeHandle());
        const monitor = c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST);
        var info = std.mem.zeroes(c.MONITORINFOEXW);
        info.unnamed_0.cbSize = @sizeOf(c.MONITORINFOEXW);
        if (c.GetMonitorInfoW(monitor, @ptrCast(&info)) == 0) return failed(window);
        const dpi = c.GetDpiForWindow(hwnd);
        if (dpi == 0) return error.Closed;
        var name: [96]u8 = undefined;
        const length = try std.unicode.utf16LeToUtf8(&name, std.mem.sliceTo(&info.szDevice, 0));
        var client: c.RECT = undefined;
        var frame: c.RECT = undefined;
        var origin: c.POINT = .{ .x = 0, .y = 0 };
        if (c.GetClientRect(hwnd, &client) == 0 or c.GetWindowRect(hwnd, &frame) == 0 or c.ClientToScreen(hwnd, &origin) == 0) return failed(window);
        return .{ .key = try m.Key.init(name[0..length]), .observed = .{ .position = .{ .x = origin.x, .y = origin.y }, .width = @intCast(@max(0, c.MulDiv(client.right, 96, @intCast(dpi)))), .height = @intCast(@max(0, c.MulDiv(client.bottom, 96, @intCast(dpi)))) }, .frame = try rect(frame), .metrics = .{ .units_per_dip = @as(f64, @floatFromInt(dpi)) / 96, .insets = .{ .left = @intCast(@max(0, @as(i64, origin.x) - frame.left)), .top = @intCast(@max(0, @as(i64, origin.y) - frame.top)), .right = @intCast(@max(0, @as(i64, frame.right) - origin.x - client.right)), .bottom = @intCast(@max(0, @as(i64, frame.bottom) - origin.y - client.bottom)) } } };
    } else if (builtin.os.tag == .linux) {
        var name: [96]u8 = undefined;
        var length: u32 = 0;
        var insets: [4]u32 = undefined;
        var client: NativeRect = undefined;
        var frame: NativeRect = undefined;
        try check(zwp_metrics(window.nativeHandle().?, &name, &length, &insets, &client, &frame));
        return .{ .key = try m.Key.init(name[0..length]), .observed = .{ .position = .{ .x = client.x, .y = client.y }, .width = client.width, .height = client.height }, .frame = .{ .x = frame.x, .y = frame.y, .width = frame.width, .height = frame.height }, .metrics = .{ .insets = .{ .left = insets[0], .top = insets[1], .right = insets[2], .bottom = insets[3] } } };
    } else return error.UnsupportedCapability;
}
