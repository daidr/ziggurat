//! OLE drag source: a delayed-rendering IDataObject over the drag's
//! Snapshot and an IDropSource, run by DoDragDrop from a helper window's
//! message once the input callback that started the drag has returned.
//! DoDragDrop tracks in the system's modal loop, as move, size and menu
//! loops do; App wakes keep being dispatched through it.
const std = @import("std");
const z = @import("ziggurat");
const drag = @import("drag.zig");
const transfer = @import("transfer.zig");
const clipboard = @import("clipboard_windows.zig");
const c = @import("ziggurat_c_win32");

pub const State = struct { data: ?*DataObject = null, drop_source: ?*DropSource = null };

const start_message: c.UINT = c.WM_APP + 0x4d2;
var helper: c.HWND = null;

pub fn schedule(source: *drag.Source) !void {
    if (helper == null) helper = try createHelper();
    if (c.PostMessageW(helper, start_message, 0, 0) == 0) return error.DragStartFailed;
    _ = source;
}
pub fn cancel(source: *drag.Source) void {
    const drop_source = source.native.drop_source orelse return;
    drop_source.canceled = c.TRUE;
    // DoDragDrop asks QueryContinueDrag again on its next input or timer.
    if (helper != null) _ = c.PostMessageW(helper, c.WM_MOUSEMOVE, 0, 0);
}
pub fn owns(source: *drag.Source, session: *anyopaque) bool {
    const data = source.native.data orelse return false;
    return @intFromPtr(data) == @intFromPtr(session);
}

fn createHelper() !c.HWND {
    const instance = c.GetModuleHandleW(null);
    const name = std.unicode.utf8ToUtf16LeStringLiteral("ZigguratDragHost");
    var class = std.mem.zeroes(c.WNDCLASSEXW);
    class.cbSize = @sizeOf(c.WNDCLASSEXW);
    class.lpfnWndProc = helperProc;
    class.hInstance = instance;
    class.lpszClassName = name;
    if (c.RegisterClassExW(&class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS) return error.DragStartFailed;
    return c.CreateWindowExW(0, name, name, 0, 0, 0, 0, 0, c.HWND_MESSAGE, null, instance, null) orelse error.DragStartFailed;
}
fn helperProc(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (message == start_message) {
        if (drag.Source.beginScheduled()) |source| run(source);
        return 0;
    }
    return c.DefWindowProcW(hwnd, message, wp, lp);
}

fn run(source: *drag.Source) void {
    const id = source.id;
    const hwnd: c.HWND = @ptrCast(source.window.nativeHandle().?);
    const ole = c.OleInitialize(null);
    if (ole < 0) return source.finish(.{ .err = error.OleInitializationFailed });
    defer c.OleUninitialize();
    const data = DataObject.create(source) catch |err| return source.finish(.{ .err = err });
    defer _ = data.vtable.Release(data);
    const drop_source = DropSource.create(hwnd) catch return source.finish(.{ .err = error.OutOfMemory });
    defer _ = drop_source.vtable.Release(drop_source);
    source.native = .{ .data = data, .drop_source = drop_source };
    if (source.previewImage()) |preview| setImage(hwnd, preview, data);
    // OLE owns the mouse capture while it tracks.
    _ = c.ReleaseCapture();
    var effect: c.DWORD = c.DROPEFFECT_NONE;
    const allowed: c.DWORD = (if (source.operations.copy) @as(c.DWORD, c.DROPEFFECT_COPY) else 0) | (if (source.operations.move) @as(c.DWORD, c.DROPEFFECT_MOVE) else 0);
    const hr = c.DoDragDrop(@ptrCast(data), @ptrCast(drop_source), allowed, &effect);
    data.source = null;
    // Cancellation or shutdown may already have finished this drag, and its
    // Source may be gone.
    if (drag.current() != source or source.id != id) return;
    source.native = .{};
    var result: drag.Result = .{ .operation = if (effect & c.DROPEFFECT_MOVE != 0) .move else if (effect & c.DROPEFFECT_COPY != 0) .copy else .none };
    if (hr != c.DRAGDROP_S_DROP) {
        result.operation = .none;
        result.canceled = hr == c.DRAGDROP_S_CANCEL or hr == c.S_OK;
        result.escaped = result.canceled and drop_source.escaped != 0;
    }
    if (hr < 0) result.err = error.DragFailed;
    if (data.failure != 0) result = .{ .err = @errorFromInt(data.failure) };
    source.finish(result);
}

const ShDragImage = extern struct { size: c.SIZE, offset: c.POINT, bitmap: c.HBITMAP, key: c.COLORREF };
const SourceHelperVtable = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*SourceHelper) callconv(.winapi) c.ULONG,
    InitializeFromBitmap: *const fn (*SourceHelper, *ShDragImage, *anyopaque) callconv(.winapi) c.HRESULT,
    InitializeFromWindow: *const anyopaque,
};
const SourceHelper = extern struct { vtable: *const SourceHelperVtable };
const clsid_drag_drop_helper: c.GUID = .{ .Data1 = 0x4657278a, .Data2 = 0x411b, .Data3 = 0x11d2, .Data4 = .{ 0x83, 0x9a, 0x00, 0xc0, 0x4f, 0xd9, 0x18, 0xd0 } };
const iid_drag_source_helper: c.GUID = .{ .Data1 = 0xde5bf786, .Data2 = 0x477a, .Data3 = 0x11d2, .Data4 = .{ 0x83, 0x9d, 0x00, 0xc0, 0x4f, 0xd9, 0x18, 0xd0 } };

/// The shell's drag image: premultiplied BGRA scaled from DIPs to the
/// window's pixels. Without the helper the default cursors remain.
fn setImage(hwnd: c.HWND, preview: drag.Preview, data: *DataObject) void {
    var object: ?*SourceHelper = null;
    if (c.CoCreateInstance(&clsid_drag_drop_helper, null, c.CLSCTX_INPROC_SERVER, &iid_drag_source_helper, @ptrCast(&object)) < 0) return;
    const helper_object = object orelse return;
    defer _ = helper_object.vtable.Release(helper_object);
    const dpi: u32 = @max(c.GetDpiForWindow(hwnd), 96);
    const width: u32 = @max(preview.width * dpi / 96, 1);
    const height: u32 = @max(preview.height * dpi / 96, 1);
    var info = std.mem.zeroes(c.BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    info.bmiHeader.biWidth = @intCast(width);
    info.bmiHeader.biHeight = -@as(c_long, @intCast(height));
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    var bits: ?*anyopaque = null;
    const bitmap = c.CreateDIBSection(null, &info, c.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    const out: [*]u8 = @ptrCast(bits.?);
    for (0..height) |y| for (0..width) |x| {
        const sx = @min(x * 96 / dpi, preview.width - 1);
        const sy = @min(y * 96 / dpi, preview.height - 1);
        const in = preview.pixels[(sy * preview.width + sx) * 4 ..][0..4];
        const alpha: u32 = in[3];
        const pixel = out[(y * width + x) * 4 ..][0..4];
        pixel.* = .{ @intCast(in[2] * alpha / 255), @intCast(in[1] * alpha / 255), @intCast(in[0] * alpha / 255), in[3] };
    };
    var image: ShDragImage = .{
        .size = .{ .cx = @intCast(width), .cy = @intCast(height) },
        .offset = .{ .x = @divTrunc(preview.hotspot_x * @as(i32, @intCast(dpi)), 96), .y = @divTrunc(preview.hotspot_y * @as(i32, @intCast(dpi)), 96) },
        .bitmap = bitmap,
        .key = 0xffffffff,
    };
    // The helper owns the bitmap once it accepted it.
    if (helper_object.vtable.InitializeFromBitmap(helper_object, &image, data) < 0) _ = c.DeleteObject(bitmap);
}

/// How a format's bytes become a native representation.
pub const Kind = enum(u8) { raw, unicode, html, url, hdrop };
const max_entries = transfer.max_formats * 2;
const max_extra = 16;
const max_name_bytes = transfer.max_formats * (transfer.max_format_bytes + 1);

pub fn registered(name: []const u8) c.CLIPFORMAT {
    var wide: [transfer.max_format_bytes + 1]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&wide, name) catch return 0;
    wide[len] = 0;
    return @truncate(c.RegisterClipboardFormatW(@ptrCast(&wide)));
}
pub fn htmlFormat() c.CLIPFORMAT {
    return registered("HTML Format");
}
pub fn pngFormat() c.CLIPFORMAT {
    return registered("PNG");
}
pub fn urlFormat() c.CLIPFORMAT {
    return registered("UniformResourceLocatorW");
}

const DataVtable = extern struct {
    QueryInterface: *const fn (*DataObject, *const c.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
    AddRef: *const fn (*DataObject) callconv(.winapi) c.ULONG,
    Release: *const fn (*DataObject) callconv(.winapi) c.ULONG,
    GetData: *const fn (*DataObject, *const c.FORMATETC, *c.STGMEDIUM) callconv(.winapi) c.HRESULT,
    GetDataHere: *const fn (*DataObject, *const c.FORMATETC, *c.STGMEDIUM) callconv(.winapi) c.HRESULT,
    QueryGetData: *const fn (*DataObject, *const c.FORMATETC) callconv(.winapi) c.HRESULT,
    GetCanonicalFormatEtc: *const fn (*DataObject, *const c.FORMATETC, *c.FORMATETC) callconv(.winapi) c.HRESULT,
    SetData: *const fn (*DataObject, *const c.FORMATETC, *c.STGMEDIUM, c.BOOL) callconv(.winapi) c.HRESULT,
    EnumFormatEtc: *const fn (*DataObject, c.DWORD, *?*anyopaque) callconv(.winapi) c.HRESULT,
    DAdvise: *const fn (*DataObject, *const c.FORMATETC, c.DWORD, ?*anyopaque, *c.DWORD) callconv(.winapi) c.HRESULT,
    DUnadvise: *const fn (*DataObject, c.DWORD) callconv(.winapi) c.HRESULT,
    EnumDAdvise: *const fn (*DataObject, *?*anyopaque) callconv(.winapi) c.HRESULT,
};
const iid_unknown: c.GUID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const iid_data_object: c.GUID = .{ .Data1 = 0x10e, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const iid_drop_source: c.GUID = .{ .Data1 = 0x121, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const iid_enum_format: c.GUID = .{ .Data1 = 0x103, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
fn sameGuid(a: *const c.GUID, b: *const c.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}
const DV_E_FORMATETC: c.HRESULT = @bitCast(@as(u32, 0x80040064));
const DV_E_TYMED: c.HRESULT = @bitCast(@as(u32, 0x80040069));
const OLE_E_ADVISENOTSUPPORTED: c.HRESULT = @bitCast(@as(u32, 0x80040003));
const DATA_S_SAMEFORMATETC: c.HRESULT = 0x40130;

fn heapCreate(comptime T: type) !*T {
    const memory = c.HeapAlloc(c.GetProcessHeap(), c.HEAP_ZERO_MEMORY, @sizeOf(T)) orelse return error.OutOfMemory;
    return @ptrCast(@alignCast(memory));
}
fn heapFree(pointer: anytype) void {
    _ = c.HeapFree(c.GetProcessHeap(), 0, pointer);
}

const Entry = extern struct { cf: c.CLIPFORMAT, kind: Kind, name_start: u16, name_len: u16 };
const Extra = extern struct { cf: c.CLIPFORMAT, global: c.HGLOBAL };

/// Native memory, freed by its last Release; it may outlive the drag, and
/// renders only while its drag is the current one.
pub const DataObject = extern struct {
    vtable: *const DataVtable,
    refs: u32,
    source: ?*drag.Source,
    id: u64,
    failure: u16,
    count: u32,
    entries: [max_entries]Entry,
    names: [max_name_bytes]u8,
    names_len: u32,
    extra_count: u32,
    extra: [max_extra]Extra,

    const vtable_value: DataVtable = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release, .GetData = getData, .GetDataHere = getDataHere, .QueryGetData = queryGetData, .GetCanonicalFormatEtc = canonical, .SetData = setData, .EnumFormatEtc = enumFormats, .DAdvise = dAdvise, .DUnadvise = dUnadvise, .EnumDAdvise = enumDAdvise };

    fn create(source: *drag.Source) !*DataObject {
        const self = try heapCreate(DataObject);
        self.vtable = &vtable_value;
        self.refs = 1;
        self.source = source;
        self.id = source.id;
        errdefer heapFree(self);
        var formats: [transfer.max_formats * 4]transfer.Format = undefined;
        const count = source.snapshot.formats(&formats);
        for (formats[0..count]) |format| {
            try self.add(registered(format), .raw, format);
            if (std.mem.eql(u8, format, transfer.text)) try self.add(c.CF_UNICODETEXT, .unicode, format);
            if (std.mem.eql(u8, format, transfer.html)) try self.add(htmlFormat(), .html, format);
            if (std.mem.eql(u8, format, transfer.png)) try self.add(pngFormat(), .raw, format);
            if (std.mem.eql(u8, format, transfer.uri_list)) try self.add(urlFormat(), .url, format);
            if (std.mem.eql(u8, format, transfer.file_list)) try self.add(c.CF_HDROP, .hdrop, format);
        }
        return self;
    }
    fn add(self: *DataObject, cf: c.CLIPFORMAT, kind: Kind, format: transfer.Format) !void {
        if (cf == 0) return;
        for (self.entries[0..self.count]) |entry| if (entry.cf == cf) return;
        if (self.count == max_entries or self.names_len + format.len > max_name_bytes) return error.TooManyFormats;
        @memcpy(self.names[self.names_len..][0..format.len], format);
        self.entries[self.count] = .{ .cf = cf, .kind = kind, .name_start = @intCast(self.names_len), .name_len = @intCast(format.len) };
        self.names_len += @intCast(format.len);
        self.count += 1;
    }
    fn find(self: *DataObject, cf: c.CLIPFORMAT) ?Entry {
        for (self.entries[0..self.count]) |entry| if (entry.cf == cf) return entry;
        return null;
    }
    fn findExtra(self: *DataObject, cf: c.CLIPFORMAT) ?*Extra {
        for (self.extra[0..self.extra_count]) |*extra| if (extra.cf == cf) return extra;
        return null;
    }
    fn live(self: *DataObject) ?*drag.Source {
        const source = self.source orelse return null;
        if (drag.current() != source or source.id != self.id or source.state != .running) return null;
        return source;
    }

    fn queryInterface(self: *DataObject, iid: *const c.GUID, out: *?*anyopaque) callconv(.winapi) c.HRESULT {
        if (sameGuid(iid, &iid_unknown) or sameGuid(iid, &iid_data_object)) {
            out.* = self;
            _ = addRef(self);
            return c.S_OK;
        }
        out.* = null;
        return c.E_NOINTERFACE;
    }
    fn addRef(self: *DataObject) callconv(.winapi) c.ULONG {
        self.refs += 1;
        return self.refs;
    }
    fn release(self: *DataObject) callconv(.winapi) c.ULONG {
        self.refs -= 1;
        const remaining = self.refs;
        if (remaining == 0) {
            for (self.extra[0..self.extra_count]) |extra| _ = c.GlobalFree(extra.global);
            heapFree(self);
        }
        return remaining;
    }
    fn valid(format: *const c.FORMATETC) bool {
        return format.dwAspect == c.DVASPECT_CONTENT and format.lindex == -1;
    }
    fn getData(self: *DataObject, format: *const c.FORMATETC, medium: *c.STGMEDIUM) callconv(.winapi) c.HRESULT {
        medium.* = std.mem.zeroes(c.STGMEDIUM);
        if (!valid(format)) return DV_E_FORMATETC;
        if (self.findExtra(format.cfFormat)) |extra| {
            if (format.tymed & c.TYMED_HGLOBAL == 0) return DV_E_TYMED;
            const copy = c.OleDuplicateData(extra.global, format.cfFormat, 0) orelse return c.E_OUTOFMEMORY;
            medium.tymed = c.TYMED_HGLOBAL;
            medium.unnamed_0.hGlobal = copy;
            return c.S_OK;
        }
        const entry = self.find(format.cfFormat) orelse return DV_E_FORMATETC;
        if (format.tymed & (c.TYMED_HGLOBAL | c.TYMED_ISTREAM) == 0) return DV_E_TYMED;
        const source = self.live() orelse return c.E_FAIL;
        const name = self.names[entry.name_start..][0..entry.name_len];
        const bytes = source.render(name) catch |err| {
            self.failure = @intFromError(err);
            return c.E_FAIL;
        };
        const global = nativeBytes(source.allocator, entry.kind, bytes) catch return c.E_FAIL;
        if (format.tymed & c.TYMED_HGLOBAL != 0) {
            medium.tymed = c.TYMED_HGLOBAL;
            medium.unnamed_0.hGlobal = global.handle;
            return c.S_OK;
        }
        // A stream keeps the exact length, which HGLOBAL sizes may round up.
        var stream: ?*c.IStream = null;
        if (c.CreateStreamOnHGlobal(global.handle, c.TRUE, &stream) < 0) {
            _ = c.GlobalFree(global.handle);
            return c.E_OUTOFMEMORY;
        }
        const s = stream.?;
        var size: c.ULARGE_INTEGER = undefined;
        size.QuadPart = global.len;
        _ = s.lpVtbl.*.SetSize.?(s, size);
        var zero: c.LARGE_INTEGER = undefined;
        zero.QuadPart = 0;
        _ = s.lpVtbl.*.Seek.?(s, zero, c.STREAM_SEEK_END, null);
        medium.tymed = c.TYMED_ISTREAM;
        medium.unnamed_0.pstm = s;
        return c.S_OK;
    }
    fn getDataHere(_: *DataObject, _: *const c.FORMATETC, _: *c.STGMEDIUM) callconv(.winapi) c.HRESULT {
        return c.E_NOTIMPL;
    }
    fn queryGetData(self: *DataObject, format: *const c.FORMATETC) callconv(.winapi) c.HRESULT {
        if (!valid(format)) return DV_E_FORMATETC;
        if (self.findExtra(format.cfFormat) != null) return if (format.tymed & c.TYMED_HGLOBAL != 0) c.S_OK else DV_E_TYMED;
        if (self.find(format.cfFormat) == null) return DV_E_FORMATETC;
        return if (format.tymed & (c.TYMED_HGLOBAL | c.TYMED_ISTREAM) != 0) c.S_OK else DV_E_TYMED;
    }
    fn canonical(_: *DataObject, in: *const c.FORMATETC, out: *c.FORMATETC) callconv(.winapi) c.HRESULT {
        out.* = in.*;
        out.ptd = null;
        return DATA_S_SAMEFORMATETC;
    }
    /// The shell's drag image helper stores its own formats here.
    fn setData(self: *DataObject, format: *const c.FORMATETC, medium: *c.STGMEDIUM, owned: c.BOOL) callconv(.winapi) c.HRESULT {
        if (!valid(format) or medium.tymed != c.TYMED_HGLOBAL) return DV_E_FORMATETC;
        // A copy we own; an owned medium is released as its owner asked.
        const global = c.OleDuplicateData(medium.unnamed_0.hGlobal, format.cfFormat, 0) orelse return c.E_OUTOFMEMORY;
        if (self.findExtra(format.cfFormat)) |extra| {
            _ = c.GlobalFree(extra.global);
            extra.global = global;
        } else if (self.extra_count < max_extra) {
            self.extra[self.extra_count] = .{ .cf = format.cfFormat, .global = global };
            self.extra_count += 1;
        } else {
            _ = c.GlobalFree(global);
            return c.E_OUTOFMEMORY;
        }
        if (owned != 0) c.ReleaseStgMedium(medium);
        return c.S_OK;
    }
    fn enumFormats(self: *DataObject, direction: c.DWORD, out: *?*anyopaque) callconv(.winapi) c.HRESULT {
        out.* = null;
        if (direction != c.DATADIR_GET) return c.E_NOTIMPL;
        const enumerator = heapCreate(FormatEnum) catch return c.E_OUTOFMEMORY;
        enumerator.vtable = &FormatEnum.vtable_value;
        enumerator.refs = 1;
        for (self.entries[0..self.count]) |entry| enumerator.push(entry.cf, c.TYMED_HGLOBAL | c.TYMED_ISTREAM);
        for (self.extra[0..self.extra_count]) |extra| enumerator.push(extra.cf, c.TYMED_HGLOBAL);
        out.* = enumerator;
        return c.S_OK;
    }
    fn dAdvise(_: *DataObject, _: *const c.FORMATETC, _: c.DWORD, _: ?*anyopaque, _: *c.DWORD) callconv(.winapi) c.HRESULT {
        return OLE_E_ADVISENOTSUPPORTED;
    }
    fn dUnadvise(_: *DataObject, _: c.DWORD) callconv(.winapi) c.HRESULT {
        return OLE_E_ADVISENOTSUPPORTED;
    }
    fn enumDAdvise(_: *DataObject, out: *?*anyopaque) callconv(.winapi) c.HRESULT {
        out.* = null;
        return OLE_E_ADVISENOTSUPPORTED;
    }
};

const Global = struct { handle: c.HGLOBAL, len: usize };
fn globalCopy(bytes: []const u8) !Global {
    const handle = c.GlobalAlloc(c.GMEM_MOVEABLE, @max(bytes.len, 1)) orelse return error.OutOfMemory;
    const pointer: [*]u8 = @ptrCast(c.GlobalLock(handle) orelse {
        _ = c.GlobalFree(handle);
        return error.OutOfMemory;
    });
    @memcpy(pointer[0..bytes.len], bytes);
    _ = c.GlobalUnlock(handle);
    return .{ .handle = handle, .len = bytes.len };
}
/// A format's bytes as its native representation in new global memory.
fn nativeBytes(allocator: std.mem.Allocator, kind: Kind, bytes: []const u8) !Global {
    switch (kind) {
        .raw => return globalCopy(bytes),
        .unicode, .url => {
            var line = bytes;
            if (kind == .url) {
                var uris: transfer.UriIterator = .init(bytes);
                line = uris.next() orelse return error.FormatUnavailable;
            }
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, line);
            defer allocator.free(wide);
            return globalCopy(std.mem.sliceAsBytes(wide[0 .. wide.len + 1]));
        },
        .html => {
            const document = try allocator.alloc(u8, clipboard.htmlSize(bytes.len));
            defer allocator.free(document);
            clipboard.writeHtml(document, bytes);
            return globalCopy(document);
        },
        .hdrop => {
            const single = [_]transfer.Item{.{ .representations = &.{.fromBytes(transfer.uri_list, bytes)} }};
            const paths = try transfer.files(allocator, .{ .items = &single });
            defer allocator.free(paths);
            if (paths.len == 0) return error.FormatUnavailable;
            const list = try allocator.alloc(u8, try clipboard.filesSize(paths));
            defer allocator.free(list);
            @memset(list, 0);
            clipboard.writeFiles(list, paths);
            return globalCopy(list);
        },
    }
}

const FormatEnumVtable = extern struct {
    QueryInterface: *const fn (*FormatEnum, *const c.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
    AddRef: *const fn (*FormatEnum) callconv(.winapi) c.ULONG,
    Release: *const fn (*FormatEnum) callconv(.winapi) c.ULONG,
    Next: *const fn (*FormatEnum, c.ULONG, [*]c.FORMATETC, ?*c.ULONG) callconv(.winapi) c.HRESULT,
    Skip: *const fn (*FormatEnum, c.ULONG) callconv(.winapi) c.HRESULT,
    Reset: *const fn (*FormatEnum) callconv(.winapi) c.HRESULT,
    Clone: *const fn (*FormatEnum, *?*anyopaque) callconv(.winapi) c.HRESULT,
};
const FormatEnum = extern struct {
    vtable: *const FormatEnumVtable,
    refs: u32,
    index: u32,
    count: u32,
    items: [max_entries + max_extra]c.FORMATETC,

    const vtable_value: FormatEnumVtable = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release, .Next = next, .Skip = skip, .Reset = reset, .Clone = clone };

    fn push(self: *FormatEnum, cf: c.CLIPFORMAT, tymed: c.DWORD) void {
        if (self.count == self.items.len) return;
        self.items[self.count] = .{ .cfFormat = cf, .ptd = null, .dwAspect = c.DVASPECT_CONTENT, .lindex = -1, .tymed = tymed };
        self.count += 1;
    }
    fn queryInterface(self: *FormatEnum, iid: *const c.GUID, out: *?*anyopaque) callconv(.winapi) c.HRESULT {
        if (sameGuid(iid, &iid_unknown) or sameGuid(iid, &iid_enum_format)) {
            out.* = self;
            _ = addRef(self);
            return c.S_OK;
        }
        out.* = null;
        return c.E_NOINTERFACE;
    }
    fn addRef(self: *FormatEnum) callconv(.winapi) c.ULONG {
        self.refs += 1;
        return self.refs;
    }
    fn release(self: *FormatEnum) callconv(.winapi) c.ULONG {
        self.refs -= 1;
        const remaining = self.refs;
        if (remaining == 0) heapFree(self);
        return remaining;
    }
    fn next(self: *FormatEnum, wanted: c.ULONG, out: [*]c.FORMATETC, fetched: ?*c.ULONG) callconv(.winapi) c.HRESULT {
        const n = @min(wanted, self.count - self.index);
        for (0..n) |i| out[i] = self.items[self.index + i];
        self.index += n;
        if (fetched) |value| value.* = n;
        return if (n == wanted) c.S_OK else c.S_FALSE;
    }
    fn skip(self: *FormatEnum, wanted: c.ULONG) callconv(.winapi) c.HRESULT {
        const n = @min(wanted, self.count - self.index);
        self.index += n;
        return if (n == wanted) c.S_OK else c.S_FALSE;
    }
    fn reset(self: *FormatEnum) callconv(.winapi) c.HRESULT {
        self.index = 0;
        return c.S_OK;
    }
    fn clone(self: *FormatEnum, out: *?*anyopaque) callconv(.winapi) c.HRESULT {
        const copy = heapCreate(FormatEnum) catch {
            out.* = null;
            return c.E_OUTOFMEMORY;
        };
        copy.* = self.*;
        copy.refs = 1;
        out.* = copy;
        return c.S_OK;
    }
};

const DropSourceVtable = extern struct {
    QueryInterface: *const fn (*DropSource, *const c.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
    AddRef: *const fn (*DropSource) callconv(.winapi) c.ULONG,
    Release: *const fn (*DropSource) callconv(.winapi) c.ULONG,
    QueryContinueDrag: *const fn (*DropSource, c.BOOL, c.DWORD) callconv(.winapi) c.HRESULT,
    GiveFeedback: *const fn (*DropSource, c.DWORD) callconv(.winapi) c.HRESULT,
};
pub const DropSource = extern struct {
    vtable: *const DropSourceVtable,
    refs: u32,
    hwnd: c.HWND,
    canceled: c.BOOL,
    escaped: c.BOOL,

    const vtable_value: DropSourceVtable = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release, .QueryContinueDrag = queryContinue, .GiveFeedback = feedback };

    fn create(hwnd: c.HWND) !*DropSource {
        const self = try heapCreate(DropSource);
        self.* = .{ .vtable = &vtable_value, .refs = 1, .hwnd = hwnd, .canceled = c.FALSE, .escaped = c.FALSE };
        return self;
    }
    fn queryInterface(self: *DropSource, iid: *const c.GUID, out: *?*anyopaque) callconv(.winapi) c.HRESULT {
        if (sameGuid(iid, &iid_unknown) or sameGuid(iid, &iid_drop_source)) {
            out.* = self;
            _ = addRef(self);
            return c.S_OK;
        }
        out.* = null;
        return c.E_NOINTERFACE;
    }
    fn addRef(self: *DropSource) callconv(.winapi) c.ULONG {
        self.refs += 1;
        return self.refs;
    }
    fn release(self: *DropSource) callconv(.winapi) c.ULONG {
        self.refs -= 1;
        const remaining = self.refs;
        if (remaining == 0) heapFree(self);
        return remaining;
    }
    /// Escape, `cancel` and the source window closing give the drag up;
    /// releasing the buttons drops it.
    fn queryContinue(self: *DropSource, escape: c.BOOL, keys: c.DWORD) callconv(.winapi) c.HRESULT {
        if (escape != 0 or self.canceled != 0 or c.IsWindow(self.hwnd) == 0) {
            self.escaped = c.TRUE;
            return c.DRAGDROP_S_CANCEL;
        }
        if (keys & (c.MK_LBUTTON | c.MK_RBUTTON | c.MK_MBUTTON) == 0) return c.DRAGDROP_S_DROP;
        return c.S_OK;
    }
    fn feedback(_: *DropSource, _: c.DWORD) callconv(.winapi) c.HRESULT {
        return c.DRAGDROP_S_USEDEFAULTCURSORS;
    }
};
