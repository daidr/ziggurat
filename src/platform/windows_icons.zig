const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});

// Resource identifiers are integer tokens encoded as pointers, including odd IDs.
// Their ABI must not impose the alignment of the optional UTF-16 string form.
const native = struct {
    extern "kernel32" fn FindResourceW(?*anyopaque, ?*const anyopaque, ?*const anyopaque) callconv(.winapi) ?*anyopaque;
    extern "user32" fn LoadImageW(?*anyopaque, ?*const anyopaque, c_uint, c_int, c_int, c_uint) callconv(.winapi) ?*anyopaque;
};

pub const resource_id: u16 = 101;

/// Owned icon pair. All operations run on the process main thread.
/// Remove windows/class references before deinit; handles are never LR_SHARED.
pub const Icons = struct {
    large: ?*anyopaque = null,
    small: ?*anyopaque = null,

    pub fn load(instance: ?*anyopaque, dpi: u32) !Icons {
        if (dpi == 0) {
            c.SetLastError(c.ERROR_INVALID_PARAMETER);
            return error.InvalidDpi;
        }
        const name: *const anyopaque = @ptrFromInt(resource_id);
        if (native.FindResourceW(instance, name, @ptrFromInt(14)) == null) return error.IconResourceMissing;
        var result: Icons = .{};
        errdefer {
            const code = c.GetLastError();
            result.deinit();
            c.SetLastError(code);
        }
        result.large = native.LoadImageW(instance, name, c.IMAGE_ICON, c.GetSystemMetricsForDpi(c.SM_CXICON, dpi), c.GetSystemMetricsForDpi(c.SM_CYICON, dpi), 0) orelse return error.LoadIconFailed;
        result.small = native.LoadImageW(instance, name, c.IMAGE_ICON, c.GetSystemMetricsForDpi(c.SM_CXSMICON, dpi), c.GetSystemMetricsForDpi(c.SM_CYSMICON, dpi), 0) orelse return error.LoadIconFailed;
        return result;
    }

    /// Window-specific pair only. Class icons stay alive until class unregister.
    /// Install both replacement handles before releasing the old pair.
    pub fn reload(self: *Icons, instance: ?*anyopaque, dpi: u32, hwnd: ?*anyopaque) !void {
        const replacement = try load(instance, dpi);
        replacement.apply(hwnd);
        self.deinit();
        self.* = replacement;
    }

    pub fn apply(self: *const Icons, hwnd: ?*anyopaque) void {
        _ = c.SendMessageW(hwnd, c.WM_SETICON, c.ICON_BIG, @bitCast(@intFromPtr(self.large)));
        _ = c.SendMessageW(hwnd, c.WM_SETICON, c.ICON_SMALL, @bitCast(@intFromPtr(self.small)));
    }

    pub fn deinit(self: *Icons) void {
        if (self.large) |icon| _ = c.DestroyIcon(icon);
        if (self.small) |icon| _ = c.DestroyIcon(icon);
        self.* = .{};
    }
};
