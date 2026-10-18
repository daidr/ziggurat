const std = @import("std");
const icons = @import("ziggurat_windows_icons");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});
const name = std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat.Packaging.Smoke");
const product_name = std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat \"资源\" & packaging \\ test");
extern "kernel32" fn FindResourceW(?*anyopaque, ?*const anyopaque, ?*const anyopaque) callconv(.winapi) ?*anyopaque;

fn resource(instance: c.HINSTANCE, id: u16, kind: u16) ![]const u8 {
    const found = FindResourceW(instance, @ptrFromInt(id), @ptrFromInt(kind));
    if (found == null) return error.ResourceMissing;
    const loaded = c.LoadResource(instance, found);
    if (loaded == null) return error.ResourceLoadFailed;
    const address = c.LockResource(loaded) orelse return error.ResourceLockFailed;
    const bytes: [*]const u8 = @ptrCast(address);
    return bytes[0..c.SizeofResource(instance, found)];
}

fn iconSize(icon: ?*anyopaque, width: c_int, height: c_int) !void {
    var info: c.ICONINFO = undefined;
    if (c.GetIconInfo(icon, &info) == 0) return error.IconInfoFailed;
    defer if (info.hbmColor != null) {
        _ = c.DeleteObject(info.hbmColor);
    };
    defer if (info.hbmMask != null) {
        _ = c.DeleteObject(info.hbmMask);
    };
    var bitmap: c.BITMAP = undefined;
    if (c.GetObjectW(info.hbmColor, @sizeOf(c.BITMAP), &bitmap) == 0) return error.BitmapInfoFailed;
    try std.testing.expectEqual(width, bitmap.bmWidth);
    try std.testing.expectEqual(height, bitmap.bmHeight);
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}
fn read32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

pub fn main() !void {
    const instance = c.GetModuleHandleW(null);
    const manifest = try resource(instance, 1, 24);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "name=\"org.ziggurat.PackagingSmoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "version=\"1.2.3.4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Ziggurat &quot;资源&quot; &amp; packaging \\ test") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "level=\"asInvoker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "PerMonitorV2") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "longPathAware") != null);
    const version = try resource(instance, 1, 16);
    var offset: usize = 6;
    while (offset + 2 <= version.len and read16(version, offset) != 0) offset += 2;
    offset = std.mem.alignForward(usize, offset + 2, 4);
    try std.testing.expect(offset + 24 <= version.len);
    try std.testing.expectEqual(@as(u32, 0xfeef04bd), read32(version, offset));
    try std.testing.expectEqual(@as(u32, 0x00010002), read32(version, offset + 8));
    try std.testing.expectEqual(@as(u32, 0x00030004), read32(version, offset + 12));
    try std.testing.expect(std.mem.indexOf(u8, version, std.mem.sliceAsBytes(product_name)) != null);
    const group = try resource(instance, icons.resource_id, 14);
    try std.testing.expectEqual(@as(u16, 1), read16(group, 2));
    const sizes = [_]u16{ 16, 20, 24, 32, 40, 48, 64, 128, 256 };
    try std.testing.expectEqual(sizes.len, read16(group, 4));
    try std.testing.expectEqual(6 + 14 * sizes.len, group.len);
    for (sizes, 0..) |size, index| {
        const entry = group[6 + index * 14 ..][0..14];
        try std.testing.expectEqual(size, if (entry[0] == 0) @as(u16, 256) else entry[0]);
        try std.testing.expectEqual(@as(u16, 32), read16(entry, 6));
        const image = try resource(instance, read16(entry, 12), 3);
        try std.testing.expectEqualSlices(u8, &.{ 137, 80, 78, 71, 13, 10, 26, 10 }, image[0..8]);
        try std.testing.expectEqual(@as(u32, size), std.mem.readInt(u32, image[16..20], .big));
        try std.testing.expectEqual(@as(u32, size), std.mem.readInt(u32, image[20..24], .big));
    }

    var class_icons = try icons.Icons.load(instance, 96);
    defer class_icons.deinit();
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.hInstance = instance;
    wc.lpfnWndProc = @ptrCast(&c.DefWindowProcW);
    wc.lpszClassName = name;
    wc.hIcon = class_icons.large;
    wc.hIconSm = class_icons.small;
    if (c.RegisterClassExW(&wc) == 0) return error.ClassRegistrationFailed;
    defer _ = c.UnregisterClassW(name, instance);
    var registered = std.mem.zeroes(c.WNDCLASSEXW);
    registered.cbSize = @sizeOf(c.WNDCLASSEXW);
    try std.testing.expect(c.GetClassInfoExW(instance, name, &registered) != 0);
    try std.testing.expectEqual(class_icons.large, registered.hIcon);
    try std.testing.expectEqual(class_icons.small, registered.hIconSm);
    const window = c.CreateWindowExW(0, name, name, c.WS_OVERLAPPEDWINDOW, 0, 0, 200, 100, null, null, instance, null);
    if (window == null) return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(window);
    const baseline = c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS);
    const baseline_gdi = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
    for ([_]u32{ 90, 96, 144, 192 }) |dpi| {
        var pair = try icons.Icons.load(instance, dpi);
        defer pair.deinit();
        try iconSize(pair.large, c.GetSystemMetricsForDpi(c.SM_CXICON, dpi), c.GetSystemMetricsForDpi(c.SM_CYICON, dpi));
        try iconSize(pair.small, c.GetSystemMetricsForDpi(c.SM_CXSMICON, dpi), c.GetSystemMetricsForDpi(c.SM_CYSMICON, dpi));
    }
    for (0..1000) |_| {
        var pair = try icons.Icons.load(instance, 96);
        pair.apply(window);
        const previous = pair;
        try pair.reload(instance, 192, window);
        try std.testing.expect(previous.large != pair.large and previous.small != pair.small);
        try iconSize(pair.large, c.GetSystemMetricsForDpi(c.SM_CXICON, 192), c.GetSystemMetricsForDpi(c.SM_CYICON, 192));
        try iconSize(pair.small, c.GetSystemMetricsForDpi(c.SM_CXSMICON, 192), c.GetSystemMetricsForDpi(c.SM_CYSMICON, 192));
        try std.testing.expectEqual(@intFromPtr(pair.large), @as(usize, @bitCast(c.SendMessageW(window, c.WM_GETICON, c.ICON_BIG, 0))));
        (icons.Icons{}).apply(window);
        pair.deinit();
        pair.deinit();
    }
    const after = c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS);
    try std.testing.expectEqual(baseline, after);
    try std.testing.expectEqual(baseline_gdi, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
    std.debug.print("packaging smoke passed: manifest/version/9 icon sizes, 1000 icon reloads; USER {d}->{d}\n", .{ baseline, after });
}
