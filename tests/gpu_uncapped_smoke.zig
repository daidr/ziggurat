//! With ZIGGURAT_UNCAPPED, Direct3D frames present without waiting for the
//! display, but a live resize presents paced: from the first change of size
//! until the size held a while, frames show untorn, one at a time.
const std = @import("std");
const z = @import("ziggurat");
const gpu = @import("ziggurat_ui").d3d11;
const zio = @import("ziggurat_io");
const c = @import("ziggurat_c_win32");
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat.Uncapped.Smoke");

extern "c" fn _putenv_s([*:0]const u8, [*:0]const u8) c_int;

fn paint(hwnd: c.HWND, dc: c.HDC, width: u32, height: u32) z.Paint {
    return .{ .native_window = hwnd, .native_context = dc.?, .size = .{ .width = width, .height = height, .scale = 1 }, .background = 0x202428 };
}
fn frame(renderer: *gpu.Renderer, buffer: *gpu.commands.Buffer, hwnd: c.HWND, dc: c.HDC, width: u32, height: u32) !void {
    _ = c.SetWindowPos(hwnd, null, 0, 0, @intCast(width), @intCast(height), c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    try renderer.begin(paint(hwnd, dc, width, height));
    try renderer.replay(buffer.commands(), buffer.textBytes());
    renderer.end() catch |err| if (err != error.PresentationBusy) return err;
}

pub fn main() !void {
    // Read once, as the first swap chain is made.
    if (_putenv_s("ZIGGURAT_UNCAPPED", "1") != 0) return error.EnvironmentFailed;
    const hr = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    if (hr < 0) return error.ComInitializationFailed;
    defer c.CoUninitialize();
    const instance = c.GetModuleHandleW(null);
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.hInstance = instance;
    wc.lpfnWndProc = @ptrCast(&c.DefWindowProcW);
    wc.lpszClassName = class_name;
    if (c.RegisterClassExW(&wc) == 0) return error.ClassRegistrationFailed;
    defer _ = c.UnregisterClassW(class_name, instance);
    const hwnd = c.CreateWindowExW(0, class_name, class_name, c.WS_POPUP, 0, 0, 256, 128, null, null, instance, null);
    if (hwnd == null) return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    const dc = c.GetDC(hwnd);
    if (dc == null) return error.GetDcFailed;
    defer _ = c.ReleaseDC(hwnd, dc);

    var buffer: gpu.commands.Buffer = .{};
    try buffer.fill(.{ .x = 8, .y = 8, .width = 64, .height = 32 }, 0xe04020);
    try buffer.finish();
    var renderer: gpu.Renderer = .{};
    defer renderer.deinit();
    try renderer.init(.{ .driver = .warp });

    try frame(&renderer, &buffer, hwnd, dc, 256, 128);
    try std.testing.expect(!renderer.pacedForTest());
    // Each change of size keeps the frames paced.
    try frame(&renderer, &buffer, hwnd, dc, 300, 150);
    try std.testing.expect(renderer.pacedForTest());
    try frame(&renderer, &buffer, hwnd, dc, 300, 150);
    try std.testing.expect(renderer.pacedForTest());
    try frame(&renderer, &buffer, hwnd, dc, 340, 170);
    try std.testing.expect(renderer.pacedForTest());
    // The size held: the next frame settles the swap chain, uncapped again.
    zio.sleep(600 * std.time.ns_per_ms);
    try frame(&renderer, &buffer, hwnd, dc, 340, 170);
    try std.testing.expect(!renderer.pacedForTest());
    try std.testing.expectEqual(@as(u32, 2), renderer.stats().resizes);
    std.debug.print("GPU uncapped: a resize presented paced and settled uncapped; resizes={d}, presents={d}\n", .{ renderer.stats().resizes, renderer.stats().presents });
}
