const std = @import("std");
const z = @import("ziggurat");
const api = @import("drop.zig");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("ole2.h");
    @cInclude("shellapi.h");
    @cInclude("commctrl.h");
});

pub const supported = true;

/// The OLE drop target is a refcounted native record. RegisterDragDrop and the
/// attached Zig Target each hold one reference; a window subclass revokes the
/// registration at WM_DESTROY, before the HWND disappears. OLE may release its
/// reference later, and the record then frees itself without touching Zig.
const State = extern struct {
    vtable: *const Vtable,
    refs: u32,
    target: ?*api.Target,
    hwnd: c.HWND,
    registered: c.BOOL,
    subclassed: c.BOOL,
    ole: c.BOOL,
    inside: c.BOOL,
    files: c.BOOL,
    text: c.BOOL,
    point: c.POINTL,
};
const Vtable = extern struct {
    QueryInterface: *const fn (*State, *const c.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
    AddRef: *const fn (*State) callconv(.winapi) c.ULONG,
    Release: *const fn (*State) callconv(.winapi) c.ULONG,
    DragEnter: *const fn (*State, *c.IDataObject, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) c.HRESULT,
    DragOver: *const fn (*State, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) c.HRESULT,
    DragLeave: *const fn (*State) callconv(.winapi) c.HRESULT,
    Drop: *const fn (*State, *c.IDataObject, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) c.HRESULT,
};
const vtable: Vtable = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release, .DragEnter = dragEnter, .DragOver = dragOver, .DragLeave = dragLeave, .Drop = drop };
const iid_unknown: c.GUID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const iid_drop_target: c.GUID = .{ .Data1 = 0x122, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const subclass_id: usize = 0x5a44524f50;

pub fn attach(target: *api.Target, handle: *anyopaque) !*anyopaque {
    const hwnd: c.HWND = @ptrCast(handle);
    const memory = c.HeapAlloc(c.GetProcessHeap(), c.HEAP_ZERO_MEMORY, @sizeOf(State)) orelse return error.OutOfMemory;
    const state: *State = @ptrCast(@alignCast(memory));
    state.* = std.mem.zeroes(State);
    state.vtable = &vtable;
    state.refs = 1;
    state.target = target;
    state.hwnd = hwnd;
    errdefer revoke(state);
    // OleInitialize nests over the App STA and is balanced in revoke.
    const ole = c.OleInitialize(null);
    if (ole < 0) {
        target.last_error = @bitCast(ole);
        return error.OleInitializationFailed;
    }
    state.ole = c.TRUE;
    if (c.SetWindowSubclass(hwnd, subclassProc, subclass_id, @intFromPtr(state)) == 0) {
        target.last_error = c.GetLastError();
        return error.SubclassFailed;
    }
    state.subclassed = c.TRUE;
    const registration = c.RegisterDragDrop(hwnd, @ptrCast(state));
    if (registration < 0) {
        target.last_error = @bitCast(registration);
        return error.DropRegistrationFailed;
    }
    state.registered = c.TRUE;
    return state;
}
pub fn detach(pointer: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(pointer));
    revoke(state);
}
/// Idempotent native teardown, then the Zig reference is dropped once.
fn revoke(state: *State) void {
    if (state.target == null) return;
    state.target = null;
    unregister(state);
    _ = release(state);
}
fn unregister(state: *State) void {
    if (state.registered != 0) _ = c.RevokeDragDrop(state.hwnd);
    if (state.subclassed != 0) _ = c.RemoveWindowSubclass(state.hwnd, subclassProc, subclass_id);
    if (state.ole != 0) c.OleUninitialize();
    state.registered = c.FALSE;
    state.subclassed = c.FALSE;
    state.ole = c.FALSE;
}
fn subclassProc(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM, id: c.UINT_PTR, data: c.DWORD_PTR) callconv(.winapi) c.LRESULT {
    _ = id;
    if (message == c.WM_DESTROY) {
        // The Zig Target still owns its reference; only native registration ends.
        const state: *State = @ptrFromInt(data);
        unregister(state);
    }
    return c.DefSubclassProc(hwnd, message, wp, lp);
}

fn queryInterface(self: *State, iid: *const c.GUID, out: *?*anyopaque) callconv(.winapi) c.HRESULT {
    if (std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_unknown)) or std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_drop_target))) {
        out.* = self;
        _ = addRef(self);
        return c.S_OK;
    }
    out.* = null;
    return c.E_NOINTERFACE;
}
fn addRef(self: *State) callconv(.winapi) c.ULONG {
    self.refs += 1;
    return self.refs;
}
fn release(self: *State) callconv(.winapi) c.ULONG {
    self.refs -= 1;
    const remaining = self.refs;
    if (remaining == 0) _ = c.HeapFree(c.GetProcessHeap(), 0, self);
    return remaining;
}

fn offers(data: *c.IDataObject, format: c.CLIPFORMAT) bool {
    var request: c.FORMATETC = .{ .cfFormat = format, .ptd = null, .dwAspect = c.DVASPECT_CONTENT, .lindex = -1, .tymed = c.TYMED_HGLOBAL };
    return data.lpVtbl.*.QueryGetData.?(data, &request) == c.S_OK;
}
fn clientPoint(state: *State, point: c.POINTL) z.Point {
    var client: c.POINT = .{ .x = point.x, .y = point.y };
    _ = c.ScreenToClient(state.hwnd, &client);
    const dpi: f32 = @floatFromInt(@max(c.GetDpiForWindow(state.hwnd), 1));
    return .{ .x = @as(f32, @floatFromInt(client.x)) * 96 / dpi, .y = @as(f32, @floatFromInt(client.y)) * 96 / dpi };
}
fn effect(accepted: bool, allowed: c.DWORD) c.DWORD {
    return if (accepted and allowed & c.DROPEFFECT_COPY != 0) c.DROPEFFECT_COPY else c.DROPEFFECT_NONE;
}
fn hover(state: *State, phase: api.Phase) bool {
    const target = state.target orelse return false;
    return target.hover(.{ .phase = phase, .point = clientPoint(state, state.point), .files = state.files != 0, .text = state.text != 0 });
}
fn dragEnter(self: *State, data: *c.IDataObject, keys: c.DWORD, point: c.POINTL, allowed: *c.DWORD) callconv(.winapi) c.HRESULT {
    _ = keys;
    const target = self.target orelse {
        allowed.* = c.DROPEFFECT_NONE;
        return c.S_OK;
    };
    self.files = @intFromBool(target.kinds.files and offers(data, c.CF_HDROP));
    self.text = @intFromBool(target.kinds.text and offers(data, c.CF_UNICODETEXT));
    self.point = point;
    self.inside = c.TRUE;
    allowed.* = effect(hover(self, .enter), allowed.*);
    return c.S_OK;
}
fn dragOver(self: *State, keys: c.DWORD, point: c.POINTL, allowed: *c.DWORD) callconv(.winapi) c.HRESULT {
    _ = keys;
    self.point = point;
    allowed.* = effect(self.inside != 0 and hover(self, .over), allowed.*);
    return c.S_OK;
}
fn dragLeave(self: *State) callconv(.winapi) c.HRESULT {
    if (self.inside != 0) {
        self.inside = c.FALSE;
        _ = hover(self, .leave);
    }
    return c.S_OK;
}
fn drop(self: *State, data: *c.IDataObject, keys: c.DWORD, point: c.POINTL, allowed: *c.DWORD) callconv(.winapi) c.HRESULT {
    _ = keys;
    self.point = point;
    // Close the hover first, as GTK does, so both platforms share one order.
    _ = dragLeave(self);
    const target = self.target orelse {
        allowed.* = c.DROPEFFECT_NONE;
        return c.S_OK;
    };
    const files = self.files != 0;
    if (!files and self.text == 0) {
        allowed.* = c.DROPEFFECT_NONE;
        return c.S_OK;
    }
    var request: c.FORMATETC = .{ .cfFormat = if (files) c.CF_HDROP else c.CF_UNICODETEXT, .ptd = null, .dwAspect = c.DVASPECT_CONTENT, .lindex = -1, .tymed = c.TYMED_HGLOBAL };
    var medium = std.mem.zeroes(c.STGMEDIUM);
    const got = data.lpVtbl.*.GetData.?(data, &request, &medium);
    const at = clientPoint(self, point);
    if (got < 0) {
        target.drop(at, .{ .failed = .{ .err = error.NativeFailure, .code = @bitCast(got) } });
        allowed.* = c.DROPEFFECT_NONE;
        return c.S_OK;
    }
    defer c.ReleaseStgMedium(&medium);
    const handle = medium.unnamed_0.hGlobal;
    var ok = false;
    if (files) {
        ok = deliverFiles(target, at, @ptrCast(handle));
    } else if (c.GlobalLock(handle)) |pointer| {
        defer _ = c.GlobalUnlock(handle);
        ok = deliverText(target, at, @ptrCast(pointer), c.GlobalSize(handle));
    } else target.drop(at, .{ .failed = .{ .err = error.NativeFailure, .code = c.GetLastError() } });
    allowed.* = effect(ok, allowed.*);
    return c.S_OK;
}

/// Conversion goes into the Target buffer directly; nothing larger than the
/// buffer is published and the required size is reported instead.
fn deliverText(target: *api.Target, at: z.Point, bytes: [*]const u8, size: usize) bool {
    const wide: [*]align(1) const u16 = @ptrCast(bytes);
    var count: usize = 0;
    while (count < size / 2 and wide[count] != 0) : (count += 1) {}
    const needed = utf8Length(wide[0..count]) orelse {
        target.drop(at, .{ .failed = .{ .err = error.InvalidUtf16 } });
        return false;
    };
    if (needed > target.buffer.len) {
        target.drop(at, .{ .capacity_exceeded = needed });
        return false;
    }
    target.drop(at, .{ .text = encodeUtf8(wide[0..count], target.buffer) });
    return true;
}
fn deliverFiles(target: *api.Target, at: z.Point, drop_handle: c.HDROP) bool {
    const count = c.DragQueryFileW(drop_handle, 0xffffffff, null, 0);
    if (count == 0 or count > api.max_files) {
        target.drop(at, .{ .failed = .{ .err = if (count == 0) error.DropMalformed else error.TooManyFiles } });
        return false;
    }
    var wide: [32768]u16 = undefined;
    var needed: usize = 0;
    for (0..count) |index| {
        const length = c.DragQueryFileW(drop_handle, @intCast(index), &wide, wide.len);
        const bytes = if (length == 0 or length >= wide.len) null else utf8Length(wide[0..length]);
        needed += (bytes orelse {
            target.drop(at, .{ .failed = .{ .err = error.DropMalformed } });
            return false;
        }) + @intFromBool(index != 0);
    }
    if (needed > target.buffer.len) {
        target.drop(at, .{ .capacity_exceeded = needed });
        return false;
    }
    var used: usize = 0;
    for (0..count) |index| {
        const length = c.DragQueryFileW(drop_handle, @intCast(index), &wide, wide.len);
        if (index != 0) {
            target.buffer[used] = 0;
            used += 1;
        }
        if (length == 0 or length >= wide.len or (utf8Length(wide[0..length]) orelse 0) > needed - used) {
            target.drop(at, .{ .failed = .{ .err = error.DropMalformed } });
            return false;
        }
        used += encodeUtf8(wide[0..length], target.buffer[used..needed]).len;
    }
    target.drop(at, .{ .files = target.buffer[0..used] });
    return true;
}
fn utf8Length(wide: []align(1) const u16) ?usize {
    var needed: usize = 0;
    var index: usize = 0;
    while (index < wide.len) : (index += 1) {
        const unit = wide[index];
        if (unit >= 0xd800 and unit <= 0xdbff) {
            if (index + 1 >= wide.len or wide[index + 1] < 0xdc00 or wide[index + 1] > 0xdfff) return null;
            needed += 4;
            index += 1;
        } else if (unit >= 0xdc00 and unit <= 0xdfff) {
            return null;
        } else needed += if (unit < 0x80) 1 else if (unit < 0x800) 2 else 3;
    }
    return needed;
}
fn encodeUtf8(wide: []align(1) const u16, destination: []u8) []const u8 {
    var used: usize = 0;
    var index: usize = 0;
    while (index < wide.len) : (index += 1) {
        var point: u21 = wide[index];
        if (point >= 0xd800 and point <= 0xdbff) {
            point = 0x10000 + ((point - 0xd800) << 10) + (wide[index + 1] - 0xdc00);
            index += 1;
        }
        used += std.unicode.utf8Encode(point, destination[used..]) catch unreachable;
    }
    return destination[0..used];
}

/// OLE stores the registered target in this window property.
pub fn registered(handle: *anyopaque) bool {
    return c.GetPropW(@ptrCast(handle), std.unicode.utf8ToUtf16LeStringLiteral("OleDropTargetInterface")) != null;
}
