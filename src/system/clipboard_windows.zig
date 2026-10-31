const std = @import("std");
const api = @import("clipboard.zig");
const bitmap = @import("bitmap.zig");
const c = @import("ziggurat_c_win32");

pub const supported = true;
/// A private message-only HWND per Board owns the clipboard, receives delayed
/// render requests, update notifications and retry timers. Nothing is global
/// except the shared window class registration.
pub const BoardState = struct {
    hwnd: c.HWND = null,
    listening: bool = false,
    posted: bool = false,
    timer: bool = false,
    ids: [api.max_formats]c.UINT = undefined,
};
pub const RequestState = struct {
    outcome: ?api.Result = null,
    waiting: bool = false,
};

const complete_message: c.UINT = c.WM_APP + 0x431;
const retry_timer: usize = 1;
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigguratClipboardBoard");
var class_users: usize = 0;

pub fn open(board: *api.Board) !void {
    const instance = c.GetModuleHandleW(null);
    if (class_users == 0) {
        var wc = std.mem.zeroes(c.WNDCLASSEXW);
        wc.cbSize = @sizeOf(c.WNDCLASSEXW);
        wc.hInstance = instance;
        wc.lpfnWndProc = boardProc;
        wc.lpszClassName = class_name;
        if (c.RegisterClassExW(&wc) == 0) return failed(board, error.RegisterClassFailed);
    }
    class_users += 1;
    errdefer release();
    const message_parent: c.HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
    const hwnd = c.CreateWindowExW(0, class_name, null, 0, 0, 0, 0, 0, message_parent, null, instance, board) orelse return failed(board, error.CreateWindowFailed);
    board.native.hwnd = hwnd;
    board.native.listening = c.AddClipboardFormatListener(hwnd) != 0;
    if (!board.native.listening and board.options.on_changed != null) {
        board.last_error = c.GetLastError();
        _ = c.DestroyWindow(hwnd);
        board.native.hwnd = null;
        return error.ClipboardListenerFailed;
    }
}
fn release() void {
    class_users -= 1;
    if (class_users == 0) _ = c.UnregisterClassW(class_name, c.GetModuleHandleW(null));
}
fn failed(board: *api.Board, err: anyerror) anyerror {
    board.last_error = c.GetLastError();
    return err;
}

/// With render_on_stop, DestroyWindow delivers WM_RENDERALLFORMATS while the
/// provider is still live. Otherwise an owned offer is emptied first.
pub fn close(board: *api.Board, render_on_stop: bool) void {
    const hwnd = board.native.hwnd orelse return;
    if (board.native.timer) _ = c.KillTimer(hwnd, retry_timer);
    board.native.timer = false;
    if (board.native.listening) _ = c.RemoveClipboardFormatListener(hwnd);
    board.native.listening = false;
    if (board.provider != null and !render_on_stop) revoke(board);
    _ = c.DestroyWindow(hwnd);
    board.native.hwnd = null;
    release();
}

pub fn write(board: *api.Board, entries: []const api.Entry) !void {
    var blocks: [api.max_formats]c.HGLOBAL = undefined;
    var ids: [api.max_formats]c.UINT = undefined;
    var built: usize = 0;
    defer for (blocks[0..built]) |block| if (block != null) {
        _ = c.GlobalFree(block);
    };
    // Every block exists before the clipboard is opened, so a failed build or a
    // busy clipboard never leaves an emptied or partial system clipboard.
    for (entries) |entry| {
        ids[built] = try formatId(board, entry.format);
        blocks[built] = try globalBlock(board, entry.format.kind, entry.data);
        built += 1;
    }
    try openClipboard(board);
    defer _ = c.CloseClipboard();
    if (c.EmptyClipboard() == 0) return failed(board, error.ClipboardWriteFailed);
    for (0..built) |index| {
        if (c.SetClipboardData(ids[index], blocks[index]) == null) {
            board.last_error = c.GetLastError();
            _ = c.EmptyClipboard();
            return error.ClipboardWriteFailed;
        }
        blocks[index] = null;
    }
}
pub fn offer(board: *api.Board, formats: []const api.Format) !void {
    var ids: [api.max_formats]c.UINT = undefined;
    for (formats, 0..) |item, index| ids[index] = try formatId(board, item);
    try openClipboard(board);
    defer _ = c.CloseClipboard();
    // EmptyClipboard sends WM_DESTROYCLIPBOARD to the previous owner, which
    // ends this Board's previous offer before the new announcement.
    if (c.EmptyClipboard() == 0) return failed(board, error.ClipboardWriteFailed);
    for (formats, 0..) |_, index| {
        // Delayed rendering returns null on success; only the error code tells.
        c.SetLastError(0);
        _ = c.SetClipboardData(ids[index], null);
        if (c.GetLastError() != 0 and c.IsClipboardFormatAvailable(ids[index]) == 0) {
            board.last_error = c.GetLastError();
            _ = c.EmptyClipboard();
            return error.ClipboardWriteFailed;
        }
    }
    @memcpy(board.native.ids[0..formats.len], ids[0..formats.len]);
}
pub fn clear(board: *api.Board) !void {
    try openClipboard(board);
    defer _ = c.CloseClipboard();
    if (c.EmptyClipboard() == 0) return failed(board, error.ClipboardWriteFailed);
}
pub fn revoke(board: *api.Board) void {
    const hwnd = board.native.hwnd orelse return;
    if (c.GetClipboardOwner() != hwnd) return;
    if (c.OpenClipboard(hwnd) == 0) {
        board.last_error = c.GetLastError();
        return;
    }
    _ = c.EmptyClipboard();
    _ = c.CloseClipboard();
}
fn openClipboard(board: *api.Board) !void {
    if (c.OpenClipboard(board.native.hwnd) == 0) return failed(board, error.ClipboardBusy);
}

pub fn start(board: *api.Board, request: *api.Request) !void {
    _ = request;
    try post(board);
}
pub fn cancel(board: *api.Board, request: *api.Request) void {
    _ = board;
    request.native = .{};
}
fn post(board: *api.Board) !void {
    if (board.native.posted) return;
    if (c.PostMessageW(board.native.hwnd, complete_message, 0, 0) == 0) return failed(board, error.PostFailed);
    board.native.posted = true;
}

/// One clipboard session reads every ready request. Callbacks run only after
/// CloseClipboard, in request order, and may start or cancel requests.
fn process(board: *api.Board) void {
    board.native.posted = false;
    var reads = false;
    var cursor = board.first;
    while (cursor) |request| : (cursor = request.next) {
        if (request.native.outcome != null) continue;
        switch (request.query) {
            .formats => request.native.outcome = .{ .formats = available(board) },
            .read => reads = true,
        }
    }
    if (reads) {
        if (c.OpenClipboard(board.native.hwnd) != 0) {
            defer _ = c.CloseClipboard();
            cursor = board.first;
            while (cursor) |request| : (cursor = request.next) {
                if (request.native.outcome == null) request.native.outcome = readFormat(board, request);
            }
        } else {
            const code = c.GetLastError();
            board.last_error = code;
            var interval: u16 = std.math.maxInt(u16);
            cursor = board.first;
            while (cursor) |request| : (cursor = request.next) {
                if (request.native.outcome != null) continue;
                if (request.attempts < request.options.attempts) {
                    request.attempts += 1;
                    request.native.waiting = true;
                    interval = @min(interval, request.options.interval_ms);
                } else request.native.outcome = .{ .failed = .{ .err = error.ClipboardBusy, .code = code } };
            }
            if (interval != std.math.maxInt(u16)) {
                if (c.SetTimer(board.native.hwnd, retry_timer, interval, null) != 0) {
                    board.native.timer = true;
                } else {
                    const timer_code = c.GetLastError();
                    cursor = board.first;
                    while (cursor) |request| : (cursor = request.next) {
                        if (request.native.waiting) request.native = .{ .outcome = .{ .failed = .{ .err = error.NativeFailure, .code = timer_code } } };
                    }
                }
            }
        }
    }
    while (nextOutcome(board)) |request| {
        const outcome = request.native.outcome.?;
        request.native = .{};
        switch (outcome) {
            .data => |data| board.complete(request, .{ .data = data }),
            else => board.complete(request, outcome),
        }
    }
}
fn nextOutcome(board: *api.Board) ?*api.Request {
    var cursor = board.first;
    while (cursor) |request| : (cursor = request.next) if (request.native.outcome != null) return request;
    return null;
}
fn retry(board: *api.Board) void {
    _ = c.KillTimer(board.native.hwnd, retry_timer);
    board.native.timer = false;
    var cursor = board.first;
    while (cursor) |request| : (cursor = request.next) request.native.waiting = false;
    process(board);
}

fn available(board: *api.Board) api.Available {
    return .{
        .text = c.IsClipboardFormatAvailable(c.CF_UNICODETEXT) != 0,
        .html = if (formatId(board, .{ .kind = .html })) |id| c.IsClipboardFormatAvailable(id) != 0 else |_| false,
        .png = c.IsClipboardFormatAvailable(c.CF_DIB) != 0 or if (formatId(board, .{ .kind = .png })) |id| c.IsClipboardFormatAvailable(id) != 0 else |_| false,
        .files = c.IsClipboardFormatAvailable(c.CF_HDROP) != 0,
    };
}
fn formatId(board: *api.Board, item: api.Format) !c.UINT {
    return switch (item.kind) {
        .text => c.CF_UNICODETEXT,
        .files => c.CF_HDROP,
        .html => registered(board, std.unicode.utf8ToUtf16LeStringLiteral("HTML Format")),
        .png => registered(board, std.unicode.utf8ToUtf16LeStringLiteral("PNG")),
        .custom => {
            var wide: [api.max_name_bytes + 1]u16 = undefined;
            for (item.name, 0..) |byte, index| wide[index] = byte;
            wide[item.name.len] = 0;
            return registered(board, wide[0..item.name.len :0]);
        },
    };
}
fn registered(board: *api.Board, name: [*:0]const u16) !c.UINT {
    const id = c.RegisterClipboardFormatW(name);
    if (id == 0) return failed(board, error.FormatRegistrationFailed);
    return id;
}

/// Reads one format from the open clipboard into the request destination.
/// Foreign HGLOBAL sizes can include allocator padding; text/html stop at
/// their terminator and PNG stops at IEND, while custom bytes are returned
/// exactly as GlobalSize reports them.
fn readFormat(board: *api.Board, request: *api.Request) api.Result {
    const item = request.format();
    const id = formatId(board, item) catch return .{ .failed = .{ .err = error.NativeFailure, .code = board.last_error } };
    const handle = c.GetClipboardData(id) orelse {
        // Bitmaps, as most programs copy images, convert when no PNG stream
        // comes with them. Windows synthesizes CF_DIB from the other kinds.
        if (item.kind == .png) if (c.GetClipboardData(c.CF_DIB)) |dib| return readBitmap(@ptrCast(dib), request.destination);
        return .unavailable;
    };
    if (item.kind == .files) return readFiles(@ptrCast(handle), request.destination);
    const size = c.GlobalSize(handle);
    const pointer = c.GlobalLock(handle) orelse return .{ .failed = .{ .err = error.NativeFailure, .code = c.GetLastError() } };
    defer _ = c.GlobalUnlock(handle);
    const bytes: [*]const u8 = @ptrCast(pointer);
    return switch (item.kind) {
        .text => readText(bytes, size, request.destination),
        .html => readHtml(bytes[0..size], request.destination),
        .png => copyResult(bytes[0 .. pngLength(bytes[0..size]) orelse return malformed()], request.destination),
        .custom => copyResult(bytes[0..size], request.destination),
        .files => unreachable,
    };
}
fn readBitmap(handle: c.HGLOBAL, destination: []u8) api.Result {
    const size = c.GlobalSize(handle);
    const pointer = c.GlobalLock(handle) orelse return .{ .failed = .{ .err = error.NativeFailure, .code = c.GetLastError() } };
    defer _ = c.GlobalUnlock(handle);
    const dib = @as([*]const u8, @ptrCast(pointer))[0..size];
    const needed = bitmap.pngLength(dib) catch return malformed();
    if (needed > destination.len) return .{ .capacity_exceeded = needed };
    return .{ .data = bitmap.dibToPng(dib, destination) catch return malformed() };
}
fn malformed() api.Result {
    return .{ .failed = .{ .err = error.ClipboardMalformed } };
}
fn copyResult(data: []const u8, destination: []u8) api.Result {
    if (data.len > destination.len) return .{ .capacity_exceeded = data.len };
    @memcpy(destination[0..data.len], data);
    return .{ .data = destination[0..data.len] };
}
fn readText(bytes: [*]const u8, size: usize, destination: []u8) api.Result {
    if (size < 2) return malformed();
    const wide: [*]align(1) const u16 = @ptrCast(bytes);
    var count: usize = 0;
    while (count < size / 2 and wide[count] != 0) : (count += 1) {}
    if (count == size / 2) return malformed();
    return wideToUtf8(wide[0..count], destination);
}
fn wideToUtf8(wide: []align(1) const u16, destination: []u8) api.Result {
    const needed = utf8Length(wide) orelse return .{ .failed = .{ .err = error.InvalidUtf16 } };
    if (needed > destination.len) return .{ .capacity_exceeded = needed };
    return .{ .data = encodeUtf8(wide, destination) };
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
/// Requires validated input and enough destination for utf8Length bytes.
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

/// CF_HTML carries byte offsets into a UTF-8 document. The fragment between
/// StartFragment and EndFragment is returned without the wrapper.
fn readHtml(bytes: []const u8, destination: []u8) api.Result {
    const limit = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    const data = bytes[0..limit];
    const first = headerValue(data, "StartFragment:") orelse return malformed();
    const last = headerValue(data, "EndFragment:") orelse return malformed();
    if (first > last or last > data.len) return malformed();
    if (!std.unicode.utf8ValidateSlice(data[first..last])) return malformed();
    return copyResult(data[first..last], destination);
}
/// The fragment of a CF_HTML document, borrowed, or null when malformed.
pub fn htmlFragment(bytes: []const u8) ?[]const u8 {
    const data = bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
    const first = headerValue(data, "StartFragment:") orelse return null;
    const last = headerValue(data, "EndFragment:") orelse return null;
    if (first > last or last > data.len) return null;
    return data[first..last];
}
fn headerValue(data: []const u8, key: []const u8) ?usize {
    const header_end = std.mem.indexOf(u8, data, "<") orelse data.len;
    const at = std.mem.indexOf(u8, data[0..header_end], key) orelse return null;
    var index = at + key.len;
    var value: usize = 0;
    var digits: usize = 0;
    while (index < header_end and std.ascii.isDigit(data[index])) : (index += 1) {
        value = std.math.mul(usize, value, 10) catch return null;
        value = std.math.add(usize, value, data[index] - '0') catch return null;
        digits += 1;
    }
    return if (digits == 0) null else value;
}
pub fn pngLength(data: []const u8) ?usize {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return null;
    var index: usize = 8;
    while (data.len - index >= 12) {
        const length = std.mem.readInt(u32, data[index..][0..4], .big);
        const total = std.math.add(usize, length, 12) catch return null;
        if (total > data.len - index) return null;
        const end = index + total;
        if (std.mem.eql(u8, data[index + 4 .. index + 8], "IEND")) return end;
        index = end;
    }
    return null;
}
fn readFiles(drop: c.HDROP, destination: []u8) api.Result {
    const count = c.DragQueryFileW(drop, 0xffffffff, null, 0);
    if (count > api.max_files) return .{ .failed = .{ .err = error.TooManyFiles } };
    var wide: [32768]u16 = undefined;
    // Measure every path first so a capacity failure publishes nothing.
    var needed: usize = 0;
    for (0..count) |index| {
        const length = c.DragQueryFileW(drop, @intCast(index), &wide, wide.len);
        if (length == 0 or length >= wide.len) return malformed();
        needed += (utf8Length(wide[0..length]) orelse return .{ .failed = .{ .err = error.InvalidUtf16 } }) + @intFromBool(index != 0);
    }
    if (needed > destination.len) return .{ .capacity_exceeded = needed };
    var used: usize = 0;
    for (0..count) |index| {
        const length = c.DragQueryFileW(drop, @intCast(index), &wide, wide.len);
        if (index != 0) {
            destination[used] = 0;
            used += 1;
        }
        const remaining = needed - used;
        if (length == 0 or length >= wide.len or (utf8Length(wide[0..length]) orelse return malformed()) > remaining) return malformed();
        used += encodeUtf8(wide[0..length], destination[used..needed]).len;
    }
    return .{ .data = destination[0..used] };
}

/// Builds one moveable block in the Windows clipboard convention for kind.
fn globalBlock(board: *api.Board, kind: api.Kind, data: []const u8) !c.HGLOBAL {
    const size: usize = switch (kind) {
        .text => (std.unicode.calcUtf16LeLen(data) catch return error.InvalidUtf8) * 2 + 2,
        .html => htmlSize(data.len),
        .png, .custom => @max(data.len, 1),
        .files => filesSize(data) catch return error.InvalidPath,
    };
    const block = c.GlobalAlloc(c.GMEM_MOVEABLE | c.GMEM_ZEROINIT, size) orelse return failed(board, error.ClipboardAllocationFailed);
    errdefer _ = c.GlobalFree(block);
    const pointer = c.GlobalLock(block) orelse return failed(board, error.ClipboardAllocationFailed);
    defer _ = c.GlobalUnlock(block);
    const bytes: [*]u8 = @ptrCast(pointer);
    switch (kind) {
        .text => {
            const wide: [*]align(1) u16 = @ptrCast(bytes);
            var index: usize = 0;
            var view = std.unicode.Utf8View.initUnchecked(data).iterator();
            while (view.nextCodepoint()) |point| {
                if (point >= 0x10000) {
                    const value = point - 0x10000;
                    wide[index] = @intCast(0xd800 + (value >> 10));
                    wide[index + 1] = @intCast(0xdc00 + (value & 0x3ff));
                    index += 2;
                } else {
                    wide[index] = @intCast(point);
                    index += 1;
                }
            }
            wide[index] = 0;
        },
        .html => writeHtml(bytes[0..size], data),
        .png, .custom => @memcpy(bytes[0..data.len], data),
        .files => writeFiles(bytes[0..size], data),
    }
    return block;
}
/// shlobj DROPFILES layout; WIN32_LEAN_AND_MEAN keeps that header out.
const DropFiles = extern struct { pFiles: u32, pt: c.POINT, fNC: c.BOOL, fWide: c.BOOL };
comptime {
    std.debug.assert(@sizeOf(DropFiles) == 20);
}
const html_prefix = "<html><body>\r\n<!--StartFragment-->";
const html_suffix = "<!--EndFragment-->\r\n</body></html>";
const html_header = "Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\n";
pub fn htmlSize(fragment: usize) usize {
    return html_header.len + html_prefix.len + fragment + html_suffix.len + 1;
}
pub fn writeHtml(destination: []u8, fragment: []const u8) void {
    const start_html = html_header.len;
    const start_fragment = start_html + html_prefix.len;
    const end_fragment = start_fragment + fragment.len;
    const end_html = end_fragment + html_suffix.len;
    _ = std.fmt.bufPrint(destination, "Version:0.9\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\nStartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\n" ++ html_prefix ++ "{s}" ++ html_suffix, .{ start_html, end_html, start_fragment, end_fragment, fragment }) catch unreachable;
    destination[end_html] = 0;
}
pub fn filesSize(data: []const u8) !usize {
    var total: usize = @sizeOf(DropFiles) + 2;
    var iterator = api.paths(data);
    while (iterator.next()) |path| total += ((std.unicode.calcUtf16LeLen(path) catch return error.InvalidPath) + 1) * 2;
    return total;
}
pub fn writeFiles(destination: []u8, data: []const u8) void {
    const header: *align(1) DropFiles = @ptrCast(destination.ptr);
    header.pFiles = @sizeOf(DropFiles);
    header.fWide = c.TRUE;
    const wide: [*]align(1) u16 = @ptrCast(destination.ptr + @sizeOf(DropFiles));
    var index: usize = 0;
    var iterator = api.paths(data);
    while (iterator.next()) |path| {
        var view = std.unicode.Utf8View.initUnchecked(path).iterator();
        while (view.nextCodepoint()) |point| {
            if (point >= 0x10000) {
                const value = point - 0x10000;
                wide[index] = @intCast(0xd800 + (value >> 10));
                wide[index + 1] = @intCast(0xdc00 + (value & 0x3ff));
                index += 2;
            } else {
                wide[index] = if (point == '/') '\\' else @intCast(point);
                index += 1;
            }
        }
        wide[index] = 0;
        index += 1;
    }
    wide[index] = 0;
}

const SinkState = struct { id: c.UINT, kind: api.Kind, board: *api.Board };
pub fn sinkSet(sink: *api.Sink, data: []const u8) !void {
    const state: *SinkState = @ptrCast(@alignCast(sink.native));
    const block = try globalBlock(state.board, state.kind, data);
    // During WM_RENDERFORMAT/WM_RENDERALLFORMATS the clipboard is already open
    // for this owner; SetClipboardData takes ownership only on success.
    if (c.SetClipboardData(state.id, block) == null) {
        state.board.last_error = c.GetLastError();
        _ = c.GlobalFree(block);
        return error.ClipboardWriteFailed;
    }
}
fn renderIndex(board: *api.Board, index: usize, teardown: bool) void {
    var state: SinkState = .{ .id = board.native.ids[index], .kind = board.offered[index].kind, .board = board };
    _ = board.render(index, &state, teardown);
}

fn boardProc(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (message == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lp)));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
        return c.DefWindowProcW(hwnd, message, wp, lp);
    }
    const address = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (address == 0) return c.DefWindowProcW(hwnd, message, wp, lp);
    const board: *api.Board = @ptrFromInt(@as(usize, @bitCast(address)));
    switch (message) {
        complete_message => {
            process(board);
            return 0;
        },
        c.WM_TIMER => if (wp == retry_timer) {
            retry(board);
            return 0;
        },
        c.WM_RENDERFORMAT => {
            for (0..board.offered_count) |index| if (board.native.ids[index] == wp) {
                renderIndex(board, index, false);
                break;
            };
            return 0;
        },
        c.WM_RENDERALLFORMATS => {
            if (board.provider != null and c.OpenClipboard(hwnd) != 0) {
                defer _ = c.CloseClipboard();
                if (c.GetClipboardOwner() == hwnd) {
                    for (0..board.offered_count) |index| renderIndex(board, index, true);
                }
            }
            return 0;
        },
        c.WM_DESTROYCLIPBOARD => {
            board.ownershipLost();
            return 0;
        },
        c.WM_CLIPBOARDUPDATE => {
            board.changed();
            return 0;
        },
        c.WM_NCDESTROY => _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0),
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wp, lp);
}

test "windows clipboard conventions round trip" {
    var html: [512]u8 = undefined;
    const fragment = "<b>粗体</b>";
    writeHtml(html[0..htmlSize(fragment.len)], fragment);
    var out: [64]u8 = undefined;
    const result = readHtml(html[0..htmlSize(fragment.len)], &out);
    try std.testing.expectEqualStrings(fragment, result.data);
    const png = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x00IEND\xae\x42\x60\x82" ++ "padding";
    try std.testing.expectEqual(png.len - 7, pngLength(png).?);
}
