const std = @import("std");
const z = @import("ziggurat");
const gpu = @import("ziggurat_ui").d3d11;
const c = @import("ziggurat_c_win32");
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat.Graphics.Smoke");

fn paint(hwnd: c.HWND, dc: c.HDC, width: u32, height: u32, scale: f32) z.Paint {
    // The content's background shows beyond a frame of an older size.
    return .{ .native_window = hwnd, .native_context = dc.?, .size = .{ .width = width, .height = height, .scale = scale }, .background = 0x202428 };
}
fn finish(renderer: *gpu.Renderer) !void {
    renderer.end() catch |err| {
        // DO_NOT_WAIT is allowed to decline a busy presentation; pixel readback
        // already verifies the rendering and no UI wait is added for a test.
        if (err != error.PresentationBusy) return err;
    };
}
fn surfaceShown(renderer: *const gpu.Renderer) bool {
    const surface = renderer.surfaceForTest() orelse return false;
    return (@as(u32, @bitCast(c.GetWindowLongW(surface, c.GWL_STYLE))) & c.WS_VISIBLE) != 0;
}
fn cycle(driver: gpu.Driver, hwnd: c.HWND, dc: c.HDC) !void {
    var renderer: gpu.Renderer = .{};
    defer renderer.deinit();
    renderer.init(.{ .driver = driver }) catch |err| {
        std.debug.print("{s} initialization HRESULT=0x{x}\n", .{ @tagName(driver), @as(u32, @bitCast(renderer.last_hresult)) });
        return err;
    };
    var buffer: gpu.commands.Buffer = .{};
    try buffer.fill(.{ .x = 0, .y = 0, .width = 256, .height = 128 }, 0x123456);
    try buffer.pushClip(.{ .x = 10, .y = 10, .width = 20, .height = 20 });
    try buffer.fill(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, 0xe04020);
    try buffer.popClip();
    try buffer.text(.{ .x = 60, .y = 50, .width = 180, .height = 40 }, "图形 / 日本語 / 한글", 0xffffff);
    try buffer.finish();
    try renderer.begin(paint(hwnd, dc, 256, 128, 1));
    const frame_handle = renderer.frameReadyHandle().?;
    var handle_flags: c.DWORD = 0;
    try std.testing.expect(c.GetHandleInformation(frame_handle, &handle_flags) != 0);
    const surface = renderer.surfaceForTest().?;
    try std.testing.expect(surface != hwnd);
    try std.testing.expectEqual(hwnd, c.GetParent(surface));
    try std.testing.expectEqual(surface, renderer.swapchainWindowForTest());
    try std.testing.expect(renderer.unscaledForTest());
    try std.testing.expect(c.IsWindowEnabled(surface) == 0);
    try std.testing.expectEqual(@as(c.LRESULT, c.HTTRANSPARENT), c.SendMessageW(surface, c.WM_NCHITTEST, 0, 0));
    try std.testing.expectEqual(hwnd, c.ChildWindowFromPointEx(hwnd, .{ .x = 15, .y = 15 }, c.CWP_SKIPDISABLED));
    try std.testing.expect(!surfaceShown(&renderer));
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try std.testing.expectEqual(@as(u32, 0xe04020), try renderer.readPixelForTest(15, 15));
    try std.testing.expectEqual(@as(u32, 0x123456), try renderer.readPixelForTest(5, 5));
    try std.testing.expect((try renderer.textPixelsForTest(60, 50, 180, 40, 0x123456)) > 50);
    try finish(&renderer);
    try std.testing.expect(surfaceShown(&renderer));
    renderer.abort();
    try std.testing.expect(!surfaceShown(&renderer));
    const initial = renderer.stats();
    try std.testing.expectEqual(@as(u32, 1), initial.device_creations);
    for (0..8) |_| {
        const was_visible = surfaceShown(&renderer);
        try renderer.begin(paint(hwnd, dc, 256, 128, 1));
        try renderer.replay(buffer.commands(), buffer.textBytes());
        try finish(&renderer);
        try std.testing.expectEqual(renderer.last_hresult >= 0 or was_visible, surfaceShown(&renderer));
    }
    try std.testing.expectEqual(initial.target_creations, renderer.stats().target_creations);
    try std.testing.expectEqual(initial.device_creations, renderer.stats().device_creations);

    // Resize and DPI use the same device and rebuild only its target as needed.
    _ = c.SetWindowPos(hwnd, null, 0, 0, 384, 192, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    try renderer.begin(paint(hwnd, dc, 384, 192, 1.5));
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try std.testing.expectEqual(@as(u32, 0xe04020), try renderer.readPixelForTest(22, 22));
    try std.testing.expectEqual(@as(u32, 0x123456), try renderer.readPixelForTest(7, 7));
    try finish(&renderer);
    try std.testing.expectEqual(@as(u32, 1), renderer.stats().resizes);
    try std.testing.expectEqual(@as(u32, 1), renderer.stats().device_creations);
    try std.testing.expectEqual(frame_handle, renderer.frameReadyHandle());

    const before_dpi = renderer.stats();
    try renderer.begin(paint(hwnd, dc, 384, 192, 2));
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try std.testing.expectEqual(@as(u32, 0xe04020), try renderer.readPixelForTest(30, 30));
    try finish(&renderer);
    try std.testing.expectEqual(before_dpi.device_creations, renderer.stats().device_creations);
    try std.testing.expectEqual(before_dpi.resizes, renderer.stats().resizes);
    try std.testing.expectEqual(before_dpi.target_creations + 1, renderer.stats().target_creations);
    try std.testing.expectEqual(frame_handle, renderer.frameReadyHandle());

    renderer.injectDeviceLoss();
    try renderer.begin(paint(hwnd, dc, 384, 192, 1.5));
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try std.testing.expectError(error.DeviceLost, renderer.end());
    try std.testing.expect(!surfaceShown(&renderer));
    try std.testing.expect(renderer.frameReadyHandle() == null);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x887a0005))), renderer.last_hresult);
    try renderer.begin(paint(hwnd, dc, 384, 192, 1.5));
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try std.testing.expectEqual(@as(u32, 0xe04020), try renderer.readPixelForTest(22, 22));
    try finish(&renderer);
    renderer.injectDeviceLossOnResize();
    try std.testing.expectError(error.DeviceLost, renderer.begin(paint(hwnd, dc, 256, 128, 1)));
    try std.testing.expect(!surfaceShown(&renderer));
    try std.testing.expect(renderer.frameReadyHandle() == null);
    _ = c.SetWindowPos(hwnd, null, 0, 0, 256, 128, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    try renderer.begin(paint(hwnd, dc, 256, 128, 1));
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try finish(&renderer);
    try std.testing.expectEqual(@as(u32, 3), renderer.stats().device_creations);
    try std.testing.expectEqual(@as(u32, 2), renderer.stats().device_losses);

    // A malformed public command slice must unwind its clip scope without leaks.
    const bad = [_]gpu.commands.Command{.{ .text = .{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .color = 0, .offset = 1, .len = 99 } }};
    try renderer.begin(paint(hwnd, dc, 256, 128, 1));
    try std.testing.expectError(error.InvalidTextRange, renderer.replay(&bad, ""));
    try std.testing.expect(!renderer.active);
    try std.testing.expect(!surfaceShown(&renderer));
    const unbalanced = [_]gpu.commands.Command{.{ .push_clip = .{ .x = 0, .y = 0, .width = 10, .height = 10 } }};
    try renderer.begin(paint(hwnd, dc, 256, 128, 1));
    try std.testing.expectError(error.UnbalancedClips, renderer.replay(&unbalanced, ""));
    const invalid_utf8 = [_]gpu.commands.Command{.{ .text = .{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .color = 0, .offset = 0, .len = 1 } }};
    try renderer.begin(paint(hwnd, dc, 256, 128, 1));
    try std.testing.expectError(error.InvalidUtf8, renderer.replay(&invalid_utf8, "\xff"));
    try renderer.begin(paint(hwnd, dc, 256, 128, 1));
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try finish(&renderer);
    const old_surface = renderer.surfaceForTest().?;
    try std.testing.expect(c.DestroyWindow(old_surface) != 0);
    try std.testing.expect(renderer.surfaceForTest() == null);
    try renderer.begin(paint(hwnd, dc, 256, 128, 1));
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try finish(&renderer);
    try std.testing.expectEqual(renderer.surfaceForTest(), renderer.swapchainWindowForTest());
    const stats = renderer.stats();
    const final_frame_handle = renderer.frameReadyHandle().?;
    try std.testing.expect(c.GetHandleInformation(final_frame_handle, &handle_flags) != 0);
    std.debug.print("GPU {s}: pixel/clip/DPI/resize verified; devices={d}, targets={d}, accepted_presents={d}, injected_losses={d}, busy={d}\n", .{ @tagName(driver), stats.device_creations, stats.target_creations, stats.presents, stats.device_losses, stats.busy_presents });
    renderer.deinit();
    renderer.deinit();
    try std.testing.expect(renderer.frameReadyHandle() == null);
    try std.testing.expectEqual(@as(u32, 0), gpu.globalResourceCount());
}

pub fn main() !void {
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
    try std.testing.expectEqual(@as(u32, 0), gpu.globalResourceCount());
    try cycle(.hardware, hwnd, dc);
    try cycle(.warp, hwnd, dc);
    const doomed = c.CreateWindowExW(0, class_name, class_name, c.WS_POPUP, 0, 0, 256, 128, null, null, instance, null);
    if (doomed == null) return error.WindowCreationFailed;
    var orphan: gpu.Renderer = .{};
    defer orphan.deinit();
    try orphan.init(.{ .driver = .warp });
    try orphan.begin(paint(doomed, dc, 256, 128, 1));
    orphan.abort();
    try std.testing.expect(c.DestroyWindow(doomed) != 0);
    try std.testing.expect(orphan.surfaceForTest() == null);
    orphan.deinit();
    try std.testing.expectEqual(@as(u32, 0), gpu.globalResourceCount());
    std.debug.print("GPU smoke passed: real hidden HWND, hardware and WARP, adapter resource count=0\n", .{});
}
