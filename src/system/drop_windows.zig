const std = @import("std");
const z = @import("ziggurat");
const api = @import("drop.zig");
const c = @import("ziggurat_c_win32");

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

const transfer = @import("transfer.zig");
const drag_windows = @import("drag_windows.zig");
const clipboard_windows = @import("clipboard_windows.zig");

/// The OLE drop target of a DataTarget, refcounted like State.
const DataState = extern struct {
    vtable: *const DataVtable,
    refs: u32,
    target: ?*api.DataTarget,
    hwnd: c.HWND,
    registered: c.BOOL,
    subclassed: c.BOOL,
    ole: c.BOOL,
    inside: c.BOOL,
    data: ?*c.IDataObject,
    count: u32,
    native: [transfer.max_formats]Native,
};
/// An offered format with the native format it is read from.
const Native = extern struct { cf: c.CLIPFORMAT, kind: drag_windows.Kind };
const DataVtable = extern struct {
    QueryInterface: *const fn (*DataState, *const c.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
    AddRef: *const fn (*DataState) callconv(.winapi) c.ULONG,
    Release: *const fn (*DataState) callconv(.winapi) c.ULONG,
    DragEnter: *const fn (*DataState, *c.IDataObject, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) c.HRESULT,
    DragOver: *const fn (*DataState, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) c.HRESULT,
    DragLeave: *const fn (*DataState) callconv(.winapi) c.HRESULT,
    Drop: *const fn (*DataState, *c.IDataObject, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) c.HRESULT,
};
const data_vtable: DataVtable = .{ .QueryInterface = dataQueryInterface, .AddRef = dataAddRef, .Release = dataRelease, .DragEnter = dataEnter, .DragOver = dataOver, .DragLeave = dataLeave, .Drop = dataDrop };
const data_subclass_id: usize = 0x5a44415441;

pub fn dataAttach(target: *api.DataTarget, handle: *anyopaque) !*anyopaque {
    const hwnd: c.HWND = @ptrCast(handle);
    if (registered(handle)) return error.AlreadyAttached;
    const memory = c.HeapAlloc(c.GetProcessHeap(), c.HEAP_ZERO_MEMORY, @sizeOf(DataState)) orelse return error.OutOfMemory;
    const state: *DataState = @ptrCast(@alignCast(memory));
    state.vtable = &data_vtable;
    state.refs = 1;
    state.target = target;
    state.hwnd = hwnd;
    errdefer dataRevoke(state);
    const ole = c.OleInitialize(null);
    if (ole < 0) {
        target.last_error = @bitCast(ole);
        return error.OleInitializationFailed;
    }
    state.ole = c.TRUE;
    if (c.SetWindowSubclass(hwnd, dataSubclassProc, data_subclass_id, @intFromPtr(state)) == 0) {
        target.last_error = c.GetLastError();
        return error.SubclassFailed;
    }
    state.subclassed = c.TRUE;
    const registration = c.RegisterDragDrop(hwnd, @ptrCast(state));
    if (registration < 0) {
        target.last_error = @bitCast(registration);
        return if (registration == c.DRAGDROP_E_ALREADYREGISTERED) error.AlreadyAttached else error.DropRegistrationFailed;
    }
    state.registered = c.TRUE;
    return state;
}
pub fn dataDetach(pointer: *anyopaque) void {
    dataRevoke(@ptrCast(@alignCast(pointer)));
}
fn dataRevoke(state: *DataState) void {
    if (state.target == null) return;
    state.target = null;
    dataUnregister(state);
    forget(state);
    _ = dataRelease(state);
}
fn dataUnregister(state: *DataState) void {
    if (state.registered != 0) _ = c.RevokeDragDrop(state.hwnd);
    if (state.subclassed != 0) _ = c.RemoveWindowSubclass(state.hwnd, dataSubclassProc, data_subclass_id);
    if (state.ole != 0) c.OleUninitialize();
    state.registered = c.FALSE;
    state.subclassed = c.FALSE;
    state.ole = c.FALSE;
}
fn dataSubclassProc(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM, id: c.UINT_PTR, data: c.DWORD_PTR) callconv(.winapi) c.LRESULT {
    _ = id;
    if (message == c.WM_DESTROY) dataUnregister(@ptrFromInt(data));
    return c.DefSubclassProc(hwnd, message, wp, lp);
}
fn dataQueryInterface(self: *DataState, iid: *const c.GUID, out: *?*anyopaque) callconv(.winapi) c.HRESULT {
    if (std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_unknown)) or std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_drop_target))) {
        out.* = self;
        _ = dataAddRef(self);
        return c.S_OK;
    }
    out.* = null;
    return c.E_NOINTERFACE;
}
fn dataAddRef(self: *DataState) callconv(.winapi) c.ULONG {
    self.refs += 1;
    return self.refs;
}
fn dataRelease(self: *DataState) callconv(.winapi) c.ULONG {
    self.refs -= 1;
    const remaining = self.refs;
    if (remaining == 0) {
        forget(self);
        _ = c.HeapFree(c.GetProcessHeap(), 0, self);
    }
    return remaining;
}
fn forget(self: *DataState) void {
    if (self.data) |data| _ = data.lpVtbl.*.Release.?(data);
    self.data = null;
}

fn registeredName(cf: c.CLIPFORMAT, destination: []u8) ?[]const u8 {
    var wide: [256]u16 = undefined;
    const len = c.GetClipboardFormatNameW(cf, &wide, wide.len);
    if (len <= 0) return null;
    const bytes = std.unicode.utf16LeToUtf8(destination, wide[0..@intCast(len)]) catch return null;
    return destination[0..bytes];
}
/// The format an OLE format offers, with how to read it.
fn offerOf(cf: c.CLIPFORMAT, buffer: []u8) ?struct { format: transfer.Format, kind: drag_windows.Kind } {
    if (cf == c.CF_UNICODETEXT) return .{ .format = transfer.text, .kind = .unicode };
    if (cf == c.CF_HDROP) return .{ .format = transfer.file_list, .kind = .hdrop };
    if (cf == drag_windows.htmlFormat()) return .{ .format = transfer.html, .kind = .html };
    if (cf == drag_windows.pngFormat()) return .{ .format = transfer.png, .kind = .raw };
    if (cf == drag_windows.urlFormat()) return .{ .format = transfer.uri_list, .kind = .url };
    const name = registeredName(cf, buffer) orelse return null;
    // RichEdit's, which WordPad and Word offer.
    if (std.mem.eql(u8, name, "Rich Text Format")) return .{ .format = "text/rtf", .kind = .raw };
    return .{ .format = name, .kind = .raw };
}
fn setOffer(self: *DataState, target: *api.DataTarget, data: *c.IDataObject) void {
    target.clearOffer();
    self.count = 0;
    var enumerator: ?*c.IEnumFORMATETC = null;
    if (data.lpVtbl.*.EnumFormatEtc.?(data, c.DATADIR_GET, &enumerator) == c.S_OK) if (enumerator) |list| {
        defer _ = list.lpVtbl.*.Release.?(list);
        var guard: usize = 0;
        while (guard < 1024) : (guard += 1) {
            var format: c.FORMATETC = undefined;
            var fetched: c.ULONG = 0;
            if (list.lpVtbl.*.Next.?(list, 1, &format, &fetched) != c.S_OK or fetched != 1) break;
            if (format.ptd) |device| c.CoTaskMemFree(device);
            if (format.dwAspect == c.DVASPECT_CONTENT and format.lindex == -1 and format.tymed & (c.TYMED_HGLOBAL | c.TYMED_ISTREAM) != 0) add(self, target, format.cfFormat);
        }
    };
    // Some sources do not enumerate; ask for the common formats too.
    for ([_]c.CLIPFORMAT{ c.CF_UNICODETEXT, c.CF_HDROP, drag_windows.htmlFormat(), drag_windows.pngFormat(), drag_windows.urlFormat() }) |cf| {
        if (offers(data, cf)) add(self, target, cf);
    }
}
fn add(self: *DataState, target: *api.DataTarget, cf: c.CLIPFORMAT) void {
    var name: [512]u8 = undefined;
    const offer = offerOf(cf, &name) orelse return;
    if (!transfer.validFormat(offer.format) or target.offers(offer.format)) return;
    if (self.count == self.native.len) return;
    target.addOffer(offer.format);
    if (!target.offers(offer.format)) return;
    self.native[self.count] = .{ .cf = cf, .kind = offer.kind };
    self.count += 1;
    // A file list is also a URI list of its files.
    if (offer.kind == .hdrop and !target.offers(transfer.uri_list) and self.count < self.native.len) {
        target.addOffer(transfer.uri_list);
        self.native[self.count] = .{ .cf = cf, .kind = .hdrop };
        self.count += 1;
    }
}
/// The offered formats line up with `native`, in order.
fn nativeIndex(target: *api.DataTarget, format: transfer.Format) ?usize {
    for (target.offered[0..target.offered_count], 0..) |offered, index| if (std.mem.eql(u8, offered, format)) return index;
    return null;
}
fn nativeName(target: *api.DataTarget, format: transfer.Format) ?[]const u8 {
    const index = nativeIndex(target, format) orelse return null;
    return target.offered[index];
}
fn operationsOf(allowed: c.DWORD) transfer.Operations {
    return .{ .copy = allowed & c.DROPEFFECT_COPY != 0, .move = allowed & c.DROPEFFECT_MOVE != 0 };
}
/// Ctrl asks for copy and Shift for move.
fn suggestedOf(keys: c.DWORD) transfer.Operation {
    if (keys & c.MK_CONTROL != 0) return .copy;
    if (keys & c.MK_SHIFT != 0) return .move;
    return .none;
}
fn effectOf(operation: transfer.Operation) c.DWORD {
    return switch (operation) {
        .none => c.DROPEFFECT_NONE,
        .copy => c.DROPEFFECT_COPY,
        .move => c.DROPEFFECT_MOVE,
    };
}
fn dataPoint(state: *DataState, point: c.POINTL) z.Point {
    var client: c.POINT = .{ .x = point.x, .y = point.y };
    _ = c.ScreenToClient(state.hwnd, &client);
    const dpi: f32 = @floatFromInt(@max(c.GetDpiForWindow(state.hwnd), 1));
    return .{ .x = @as(f32, @floatFromInt(client.x)) * 96 / dpi, .y = @as(f32, @floatFromInt(client.y)) * 96 / dpi };
}
fn dataEnter(self: *DataState, data: *c.IDataObject, keys: c.DWORD, point: c.POINTL, wanted_effect: *c.DWORD) callconv(.winapi) c.HRESULT {
    const target = self.target orelse {
        wanted_effect.* = c.DROPEFFECT_NONE;
        return c.S_OK;
    };
    forget(self);
    _ = data.lpVtbl.*.AddRef.?(data);
    self.data = data;
    setOffer(self, target, data);
    self.inside = c.TRUE;
    wanted_effect.* = effectOf(target.hover(.enter, dataPoint(self, point), operationsOf(wanted_effect.*), suggestedOf(keys), data));
    return c.S_OK;
}
fn dataOver(self: *DataState, keys: c.DWORD, point: c.POINTL, wanted_effect: *c.DWORD) callconv(.winapi) c.HRESULT {
    const target = self.target orelse {
        wanted_effect.* = c.DROPEFFECT_NONE;
        return c.S_OK;
    };
    if (self.inside == 0) {
        wanted_effect.* = c.DROPEFFECT_NONE;
        return c.S_OK;
    }
    wanted_effect.* = effectOf(target.hover(.over, dataPoint(self, point), operationsOf(wanted_effect.*), suggestedOf(keys), self.data));
    return c.S_OK;
}
fn dataLeave(self: *DataState) callconv(.winapi) c.HRESULT {
    if (self.inside != 0) {
        self.inside = c.FALSE;
        if (self.target) |target| _ = target.hover(.leave, .{ .x = 0, .y = 0 }, .{}, .none, null);
    }
    forget(self);
    return c.S_OK;
}
fn dataDrop(self: *DataState, data: *c.IDataObject, keys: c.DWORD, point: c.POINTL, wanted_effect: *c.DWORD) callconv(.winapi) c.HRESULT {
    const allowed = wanted_effect.*;
    wanted_effect.* = c.DROPEFFECT_NONE;
    const at = dataPoint(self, point);
    // Close the hover first, as GTK does.
    if (self.inside != 0) {
        self.inside = c.FALSE;
        if (self.target) |target| _ = target.hover(.leave, at, .{}, .none, null);
    }
    forget(self);
    const target = self.target orelse return c.S_OK;
    setOffer(self, target, data);
    const operation = target.beginDrop(at, operationsOf(allowed), suggestedOf(keys), data, nativeName);
    if (operation == .none) return c.S_OK;
    for (target.wantedFormats()) |wanted| {
        const index = nativeIndex(target, wanted.format) orelse continue;
        const native = self.native[index];
        const bytes = readNative(target.allocator, data, native) catch null;
        defer if (bytes) |value| target.allocator.free(value);
        target.receive(wanted.native, bytes);
    }
    if (target.complete()) wanted_effect.* = effectOf(operation);
    return c.S_OK;
}

/// A native representation as the format's bytes, owned by the caller.
fn readNative(allocator: std.mem.Allocator, data: *c.IDataObject, native: Native) ![]u8 {
    if (native.kind == .hdrop) return readFiles(allocator, data);
    const raw = try readBytes(allocator, data, native.cf);
    switch (native.kind) {
        .raw => return raw,
        .unicode, .url => {
            defer allocator.free(raw);
            const wide: []align(1) const u16 = @as([*]align(1) const u16, @ptrCast(raw.ptr))[0 .. raw.len / 2];
            var end: usize = 0;
            while (end < wide.len and wide[end] != 0) : (end += 1) {}
            const length = utf8Length(wide[0..end]) orelse return error.InvalidUtf16;
            const out = try allocator.alloc(u8, length);
            _ = encodeUtf8(wide[0..end], out);
            return out;
        },
        .html => {
            defer allocator.free(raw);
            const fragment = clipboard_windows.htmlFragment(raw) orelse return error.DropMalformed;
            return allocator.dupe(u8, fragment);
        },
        .hdrop => unreachable,
    }
}
fn readBytes(allocator: std.mem.Allocator, data: *c.IDataObject, cf: c.CLIPFORMAT) ![]u8 {
    // A stream keeps the exact length; HGLOBAL sizes may include padding.
    var request: c.FORMATETC = .{ .cfFormat = cf, .ptd = null, .dwAspect = c.DVASPECT_CONTENT, .lindex = -1, .tymed = c.TYMED_ISTREAM };
    var medium = std.mem.zeroes(c.STGMEDIUM);
    if (data.lpVtbl.*.GetData.?(data, &request, &medium) >= 0) {
        defer c.ReleaseStgMedium(&medium);
        if (medium.tymed != c.TYMED_ISTREAM or medium.unnamed_0.pstm == null) return error.FormatUnavailable;
        return readStream(allocator, medium.unnamed_0.pstm);
    }
    request.tymed = c.TYMED_HGLOBAL;
    medium = std.mem.zeroes(c.STGMEDIUM);
    if (data.lpVtbl.*.GetData.?(data, &request, &medium) < 0) return error.FormatUnavailable;
    defer c.ReleaseStgMedium(&medium);
    if (medium.tymed != c.TYMED_HGLOBAL) return error.FormatUnavailable;
    const handle = medium.unnamed_0.hGlobal;
    const size = c.GlobalSize(handle);
    if (size > transfer.max_representation_bytes) return error.CapacityExceeded;
    const pointer: [*]const u8 = @ptrCast(c.GlobalLock(handle) orelse return error.NativeFailure);
    defer _ = c.GlobalUnlock(handle);
    return allocator.dupe(u8, pointer[0..size]);
}
fn readStream(allocator: std.mem.Allocator, stream: *c.IStream) ![]u8 {
    var zero: c.LARGE_INTEGER = undefined;
    zero.QuadPart = 0;
    if (stream.lpVtbl.*.Seek.?(stream, zero, c.STREAM_SEEK_SET, null) < 0) return error.NativeFailure;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        var read: c.ULONG = 0;
        const hr = stream.lpVtbl.*.Read.?(stream, &chunk, chunk.len, &read);
        if (hr < 0 or read > chunk.len) return error.NativeFailure;
        if (out.items.len + read > transfer.max_representation_bytes) return error.CapacityExceeded;
        try out.appendSlice(allocator, chunk[0..read]);
        if (read == 0 or hr == c.S_FALSE) break;
    }
    return out.toOwnedSlice(allocator);
}
/// CF_HDROP paths as a CRLF list of file URLs.
fn readFiles(allocator: std.mem.Allocator, data: *c.IDataObject) ![]u8 {
    var request: c.FORMATETC = .{ .cfFormat = c.CF_HDROP, .ptd = null, .dwAspect = c.DVASPECT_CONTENT, .lindex = -1, .tymed = c.TYMED_HGLOBAL };
    var medium = std.mem.zeroes(c.STGMEDIUM);
    if (data.lpVtbl.*.GetData.?(data, &request, &medium) < 0) return error.FormatUnavailable;
    defer c.ReleaseStgMedium(&medium);
    const drop_handle: c.HDROP = @ptrCast(medium.unnamed_0.hGlobal);
    const count = c.DragQueryFileW(drop_handle, 0xffffffff, null, 0);
    if (count == 0 or count > api.max_files) return error.DropMalformed;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var wide: [32768]u16 = undefined;
    var path: [32768 * 3]u8 = undefined;
    for (0..count) |index| {
        const length = c.DragQueryFileW(drop_handle, @intCast(index), &wide, wide.len);
        if (length == 0 or length >= wide.len) return error.DropMalformed;
        const bytes = utf8Length(wide[0..length]) orelse return error.DropMalformed;
        const utf8 = encodeUtf8(wide[0..length], path[0..bytes]);
        if (out.items.len != 0) try out.appendSlice(allocator, "\r\n");
        try transfer.fileUrl(allocator, &out, utf8);
    }
    return out.toOwnedSlice(allocator);
}
