const builtin = @import("builtin");
const z = @import("ziggurat");

/// Writes UTF-8 text on the owner thread. Windows allocates the native clipboard
/// block and transfers it to the OS on success; no Zig allocation is hidden.
pub fn writeText(window: z.Window, text: []const u8) !void {
    window.app.assertOwner();
    if (comptime builtin.os.tag != .windows) return error.UnsupportedCapability;
    const hwnd = window.nativeHandle() orelse return error.Closed;
    try z.windows_text.writeClipboard(hwnd, text);
}

/// Reads UTF-8 into caller storage. CapacityExceeded leaves ownership unchanged;
/// slices belong to the caller and no delayed rendering callback is retained.
pub fn readText(window: z.Window, destination: []u8) !usize {
    window.app.assertOwner();
    if (comptime builtin.os.tag != .windows) return error.UnsupportedCapability;
    const hwnd = window.nativeHandle() orelse return error.Closed;
    return z.windows_text.readClipboard(hwnd, destination);
}
