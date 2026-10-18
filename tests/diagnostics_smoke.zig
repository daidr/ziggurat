const std = @import("std");
const z = @import("ziggurat");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("objbase.h");
});

pub fn main() !void {
    var allocator_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator_state.deinit() == .ok);
    const allocator = allocator_state.allocator();
    var recorder: z.diagnostics.Recorder(8) = .{};
    const initialized = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
    if (initialized < 0) return error.TestComSetupFailed;
    const result = z.App.initWithOptions(allocator, .{ .diagnostics_sink = recorder.sink() });
    c.CoUninitialize();
    try std.testing.expectError(error.ComInitializationFailed, result);
    var entries: [8]z.diagnostics.Diagnostic = undefined;
    try std.testing.expectEqual(1, recorder.snapshot(&entries).count);
    try std.testing.expectEqual(z.diagnostics.Domain.hresult, entries[0].domain);
    try std.testing.expectEqual(z.diagnostics.Operation.app_init, entries[0].operation);
    try std.testing.expectEqual(@as(?u32, 0x80010106), entries[0].code);
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = recorder.sink(), .icon_policy = .required });
    defer app.deinit();
    const window = try app.createWindow(.{});
    const hwnd: c.HWND = window.nativeHandle();
    try std.testing.expect(c.SendMessageW(hwnd, c.WM_GETICON, c.ICON_BIG, 0) != 0);
    try std.testing.expect(c.SendMessageW(hwnd, c.WM_GETICON, c.ICON_SMALL, 0) != 0);
    const baseline = c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS);
    var rect: c.RECT = undefined;
    _ = c.GetWindowRect(hwnd, &rect);
    for (0..100) |_| {
        _ = c.SendMessageW(hwnd, c.WM_DPICHANGED, (144 << 16) | 144, @bitCast(@intFromPtr(&rect)));
        _ = c.SendMessageW(hwnd, c.WM_DPICHANGED, (96 << 16) | 96, @bitCast(@intFromPtr(&rect)));
    }
    try std.testing.expectEqual(baseline, c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS));
    _ = try window.destroy();
    try std.testing.expectEqual(1, recorder.snapshot(&entries).count);
    std.debug.print("diagnostics smoke passed: startup HRESULT survives rollback, retry works, 200 DPI icon reloads without USER growth\n", .{});
}
