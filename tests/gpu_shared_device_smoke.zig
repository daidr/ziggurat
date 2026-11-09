//! The windows' Direct3D 11 renderers share one device for each driver: a
//! device costs the driver tens of megabytes, which a window each would
//! multiply. The device goes with the last renderer holding it, and one
//! lost is not handed to the next renderer made, which makes another.
const std = @import("std");
const z = @import("ziggurat");
const gpu = @import("ziggurat_ui").d3d11;
const c = @import("ziggurat_c_win32");
const ui = @import("ziggurat_ui");
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat.SharedDevice.Smoke");

/// A page of two squares whose second changes color each frame asked.
const Page = struct {
    color: u32 = 0x3366cc,
    fn draw(ptr: *anyopaque, out: *ui.Frame) void {
        const self: *Page = @ptrCast(@alignCast(ptr));
        out.clear(0xffffff);
        out.rect(.{ .x = 0, .y = 0, .width = 40, .height = 40 }, 0x123456);
        out.rect(.{ .x = 60, .y = 60, .width = 20, .height = 20 }, self.color);
    }
    fn action(_: *anyopaque, _: u64) void {}
};

/// A Context on Direct3D 11 keeps its frame: once the page changes in one
/// square, the next frame draws only that square over the last, and shows
/// the same pixels as a frame drawn whole.
fn damage(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var page: Page = .{};
    var context = ui.Context.init(&page, Page.draw, Page.action);
    context.render_mode = .warp;
    const window = try app.createWindow(.{ .width = 160, .height = 120 });
    try context.attach(window);
    const hwnd: c.HWND = @ptrCast(window.nativeHandle());
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), context.gpu_frames);
    page.color = 0xcc3366;
    window.invalidate();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 3), context.gpu_frames);
    const stats = context.damageStats();
    std.debug.print("shared device smoke: partial frame of {d} rectangles\n", .{stats.gpu_last.len});
    try std.testing.expect(stats.gpu_partial_frames >= 2);
    try std.testing.expect(!stats.gpu_last.full and stats.gpu_last.len >= 1);
    try std.testing.expect(context.gpu_renderer.partialFrames() >= 2);
    try std.testing.expectEqual(@as(usize, 0), context.gdi_frames);
    // The square drawn again over the kept frame, and the rest of it.
    const scale: u32 = @intCast(@max(1, c.GetDpiForWindow(hwnd) / 96));
    try std.testing.expectEqual(@as(u32, 0x123456), try context.gpu_renderer.planePixelForTest(10 * scale, 10 * scale));
    try std.testing.expectEqual(@as(u32, 0xcc3366), try context.gpu_renderer.planePixelForTest(70 * scale, 70 * scale));
    try std.testing.expectEqual(@as(u32, 0xffffff), try context.gpu_renderer.planePixelForTest(120 * scale, 100 * scale));
    _ = try window.destroy();
    try std.testing.expectEqual(@as(u32, 0), gpu.globalResourceCount());
}

fn paint(hwnd: c.HWND, dc: c.HDC) z.Paint {
    return .{ .native_window = hwnd, .native_context = dc.?, .size = .{ .width = 64, .height = 64, .scale = 1 }, .background = 0x202428 };
}
fn finish(renderer: *gpu.Renderer) !void {
    renderer.end() catch |err| if (err != error.PresentationBusy) return err;
}
fn frame(renderer: *gpu.Renderer, hwnd: c.HWND, dc: c.HDC, color: u32) !void {
    var buffer: gpu.commands.Buffer = .{};
    try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, color);
    try buffer.finish();
    try renderer.begin(paint(hwnd, dc));
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try std.testing.expectEqual(color, try renderer.readPixelForTest(8, 8));
    try finish(renderer);
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
    var windows: [3]c.HWND = undefined;
    var dcs: [3]c.HDC = undefined;
    for (&windows, &dcs) |*hwnd, *dc| {
        hwnd.* = c.CreateWindowExW(0, class_name, class_name, c.WS_POPUP, 0, 0, 64, 64, null, null, instance, null);
        if (hwnd.* == null) return error.WindowCreationFailed;
        dc.* = c.GetDC(hwnd.*);
        if (dc.* == null) return error.GetDcFailed;
    }
    defer for (windows, dcs) |hwnd, dc| {
        _ = c.ReleaseDC(hwnd, dc);
        _ = c.DestroyWindow(hwnd);
    };
    try std.testing.expectEqual(@as(u32, 0), gpu.globalResourceCount());
    const made = gpu.Renderer.sharedDeviceCreationsForTest();

    var first: gpu.Renderer = .{};
    defer first.deinit();
    try first.init(.{ .driver = .warp });
    var second: gpu.Renderer = .{};
    defer second.deinit();
    try second.init(.{ .driver = .warp });
    // Two windows, one device; each draws its own frames on it.
    try std.testing.expect(first.sharesDeviceForTest(&second));
    try std.testing.expectEqual(@as(u32, 2), gpu.Renderer.sharedDeviceUsersForTest(.warp));
    try std.testing.expectEqual(made + 1, gpu.Renderer.sharedDeviceCreationsForTest());
    try frame(&first, windows[0], dcs[0], 0x336699);
    try frame(&second, windows[1], dcs[1], 0x993366);
    try frame(&first, windows[0], dcs[0], 0x669933);

    // The device stays while a renderer holds it.
    first.deinit();
    try std.testing.expectEqual(@as(u32, 1), gpu.Renderer.sharedDeviceUsersForTest(.warp));
    try frame(&second, windows[1], dcs[1], 0x123456);

    // A device lost leaves the slot: the next renderer makes another, and
    // the one that lost it makes its own again on that one.
    second.injectDeviceLoss();
    try second.begin(paint(windows[1], dcs[1]));
    try std.testing.expectError(error.DeviceLost, second.end());
    try std.testing.expectEqual(@as(u32, 0), gpu.Renderer.sharedDeviceUsersForTest(.warp));
    var third: gpu.Renderer = .{};
    defer third.deinit();
    try third.init(.{ .driver = .warp });
    try std.testing.expectEqual(made + 2, gpu.Renderer.sharedDeviceCreationsForTest());
    try frame(&second, windows[1], dcs[1], 0x445566);
    try std.testing.expect(second.sharesDeviceForTest(&third));
    try frame(&third, windows[2], dcs[2], 0x778899);
    try std.testing.expectEqual(@as(u32, 2), gpu.Renderer.sharedDeviceUsersForTest(.warp));

    second.deinit();
    third.deinit();
    try std.testing.expectEqual(@as(u32, 0), gpu.Renderer.sharedDeviceUsersForTest(.warp));
    try std.testing.expectEqual(@as(u32, 0), gpu.globalResourceCount());
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    try damage(debug.allocator());
    std.debug.print("shared device smoke: window renderers shared one Direct3D 11 device and made another once it was lost\n", .{});
}
