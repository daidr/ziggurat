const std = @import("std");
const core = @import("../root.zig");
const c = @import("ziggurat_c_win32");

pub const max_composition_units = 4096;
pub const InputError = error{ InvalidScalar, InvalidUtf16, CapacityExceeded, IdExhausted, InputContextUnavailable, CompositionQueryFailed, CompositionChanged, CandidatePositionFailed, InvalidGeometry, InvalidWindow, ClipboardUnavailable, ClipboardAllocationFailed, ClipboardMalformed, ClipboardWriteFailed, InvalidUtf8, EmbeddedNul };
pub const PixelRect = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, core.Event) void,
    current: ?*const fn (*anyopaque) bool = null,
    fn isCurrent(self: Sink) bool {
        return if (self.current) |check| check(self.context) else true;
    }
};

/// Per-window native text state. Scratch capacity is explicit and never grows.
/// IMM32 strings and bounded document-feed/reconversion are supported. This is
/// not a TSF text store. Events and native requests borrow stack scratch.
pub const Handler = struct {
    high_surrogate: ?u16 = null,
    composing: bool = false,
    session_epoch: u64 = 0,
    continuation_epoch: u64 = 0,
    message_epoch: u64 = 0,
    system_enabled: bool = true,
    mode_transition: bool = false,
    last_error: ?anyerror = null,
    reconversion: ?Reconversion = null,
    const Reconversion = struct {
        token: core.TextClientToken,
        revision: u64,
        range: core.text.Range,
        hash: u64,
    };
    /// One native message may emit more than once. Document edits are allowed;
    /// only a changed window, input permission, binding, mode, local session or
    /// nested producer message revokes its tail.
    const MessageGuard = struct {
        handler: *Handler,
        record: *core.WindowRecord,
        hwnd: ?*anyopaque,
        identity: usize,
        generation: u64,
        mode_epoch: u64,
        allowed: bool,
        continuation: u64,
        message: u64,
        session: u64,
        fn init(handler: *Handler, record: *core.WindowRecord, hwnd: ?*anyopaque) MessageGuard {
            return .{ .handler = handler, .record = record, .hwnd = hwnd, .identity = record.native.identity, .generation = record.text_generation, .mode_epoch = record.text_input_epoch, .allowed = record.inputAllowed(), .continuation = handler.continuation_epoch, .message = handler.message_epoch, .session = handler.session_epoch };
        }
        fn current(ptr: *anyopaque) bool {
            const self: *MessageGuard = @ptrCast(@alignCast(ptr));
            return (self.record.phase == .open or self.record.phase == .creating) and self.record.native.hwnd == self.hwnd and self.record.native.identity == self.identity and self.record.text_generation == self.generation and self.record.text_input_epoch == self.mode_epoch and self.record.inputAllowed() == self.allowed and self.handler.continuation_epoch == self.continuation and self.handler.message_epoch == self.message and self.handler.session_epoch == self.session;
        }
        fn emit(ptr: *anyopaque, value: core.Event) void {
            const self: *MessageGuard = @ptrCast(@alignCast(ptr));
            // The message may have just started/ended its own local session.
            // Only its continuation after the observer checks the old stamp.
            self.record.emit(value);
        }
    };

    pub fn process(self: *Handler, window: *core.WindowRecord, hwnd: ?*anyopaque, message: u32, wp: usize, lp: isize) ?isize {
        if (self.blocksServiceMessage(message)) return 0;
        self.beginMessage(message, wp, lp) catch |err| {
            self.last_error = err;
            window.window.report(.{ .domain = .win32, .operation = .text_input, .err = err });
            return 0;
        };
        var guard = MessageGuard.init(self, window, hwnd);
        if (message == c.WM_IME_REQUEST) return self.request(window, &guard, wp, lp) catch |err| {
            self.last_error = err;
            if (err != error.StaleTextClient and err != error.CompositionActive) window.window.report(.{ .domain = .win32, .operation = .text_input, .err = err });
            return 0;
        };
        if (message == c.WM_KILLFOCUS) {
            self.cancel(window, false) catch |err| {
                // A cancel callback may close this window deliberately. That
                // revokes input normally; it is not an IMM failure.
                if (err != error.Closed) {
                    self.last_error = err;
                    window.window.report(.{ .domain = .win32, .operation = .text_input, .err = err });
                }
            };
            return null;
        }
        const sink: Sink = .{ .context = &guard, .emit = MessageGuard.emit, .current = MessageGuard.current };
        return self.processCurrent(sink, hwnd, message, wp, lp) catch |err| {
            self.last_error = err;
            window.window.report(.{ .domain = .win32, .operation = .text_input, .err = err });
            return if (message == c.WM_KILLFOCUS) null else 0;
        };
    }
    noinline fn request(self: *Handler, record: *core.WindowRecord, guard: *MessageGuard, kind: usize, parameter: isize) !isize {
        if (kind != c.IMR_DOCUMENTFEED and kind != c.IMR_RECONVERTSTRING and kind != c.IMR_CONFIRMRECONVERTSTRING) return 0;
        const window = record.window;
        const token = window.textClientToken() orelse return 0;
        var bytes: [max_composition_units]u8 = undefined;
        const value = try window.readTextClient(token, &bytes);
        if (!MessageGuard.current(guard)) return 0;
        if (value.composition != null) return error.CompositionActive;
        var wide: [max_composition_units]u16 = undefined;
        const text = bytes[0..value.bytes];
        const units = std.unicode.utf8ToUtf16Le(&wide, text) catch return error.CapacityExceeded;
        const required = @sizeOf(c.RECONVERTSTRING) + (units + 1) * 2;
        if (kind == c.IMR_CONFIRMRECONVERTSTRING) {
            const saved = self.reconversion orelse return 0;
            // A confirmation consumes its offer even when malformed or stale.
            self.reconversion = null;
            if (parameter == 0 or !std.meta.eql(saved.token, token) or saved.revision != value.revision or !std.meta.eql(saved.range, value.range) or saved.hash != std.hash.Wyhash.hash(0, text)) return 0;
            const reconvert: *align(1) const c.RECONVERTSTRING = @ptrFromInt(@as(usize, @bitCast(parameter)));
            if (reconvert.dwVersion != 0 or reconvert.dwSize < required or reconvert.dwStrOffset != @sizeOf(c.RECONVERTSTRING) or reconvert.dwStrLen != units or reconvert.dwCompStrOffset % 2 != 0 or reconvert.dwTargetStrOffset % 2 != 0) return 0;
            const composition_start = reconvert.dwCompStrOffset / 2;
            const target_start = reconvert.dwTargetStrOffset / 2;
            if (composition_start > units or reconvert.dwCompStrLen > units - composition_start or target_start < composition_start or target_start > composition_start + reconvert.dwCompStrLen or reconvert.dwTargetStrLen > composition_start + reconvert.dwCompStrLen - target_start) return 0;
            const supplied: [*]const u8 = @ptrFromInt(@as(usize, @bitCast(parameter)) + @sizeOf(c.RECONVERTSTRING));
            if (!std.mem.eql(u8, supplied[0 .. units * 2], std.mem.sliceAsBytes(wide[0..units]))) return 0;
            // Offsets are bytes in RECONVERTSTRING and UTF-16 units in core.
            _ = core.text.byteOffset(text, composition_start) catch return 0;
            _ = core.text.byteOffset(text, composition_start + reconvert.dwCompStrLen) catch return 0;
            _ = core.text.byteOffset(text, target_start) catch return 0;
            _ = core.text.byteOffset(text, target_start + reconvert.dwTargetStrLen) catch return 0;
            const result = try window.changeTextClient(token, .{ .select = .{ .anchor = value.range.start + composition_start, .caret = value.range.start + composition_start + reconvert.dwCompStrLen } });
            return @intFromBool(result == .applied and MessageGuard.current(guard));
        }
        if (parameter == 0) return @intCast(required);
        const reconvert: *align(1) c.RECONVERTSTRING = @ptrFromInt(@as(usize, @bitCast(parameter)));
        if (reconvert.dwSize < required) return error.CapacityExceeded;
        const selected_start = @min(value.selection.anchor, value.selection.caret) - value.range.start;
        const selected_end = @max(value.selection.anchor, value.selection.caret) - value.range.start;
        reconvert.* = .{ .dwSize = @intCast(required), .dwVersion = 0, .dwStrLen = @intCast(units), .dwStrOffset = @sizeOf(c.RECONVERTSTRING), .dwCompStrLen = @intCast(selected_end - selected_start), .dwCompStrOffset = @intCast(selected_start * 2), .dwTargetStrLen = @intCast(selected_end - selected_start), .dwTargetStrOffset = @intCast(selected_start * 2) };
        const destination: [*]u8 = @ptrFromInt(@as(usize, @bitCast(parameter)) + @sizeOf(c.RECONVERTSTRING));
        @memcpy(destination[0 .. units * 2], std.mem.sliceAsBytes(wide[0..units]));
        destination[units * 2] = 0;
        destination[units * 2 + 1] = 0;
        if (kind == c.IMR_RECONVERTSTRING) self.reconversion = .{ .token = token, .revision = value.revision, .range = value.range, .hash = std.hash.Wyhash.hash(0, text) };
        return @intCast(required);
    }
    fn emitWindow(ptr: *anyopaque, event: core.Event) void {
        const window: *core.WindowRecord = @ptrCast(@alignCast(ptr));
        window.emit(event);
    }
    /// Revoke the old local session before either user or IMM callbacks. The
    /// caller holds the WindowRecord through the complete operation.
    pub fn cancel(self: *Handler, window: *core.WindowRecord, force_native: bool) !void {
        const hwnd = window.native.hwnd;
        const identity = window.native.identity;
        const generation = window.text_generation;
        const client = if (window.text_client) |value| value.context else null;
        const was_composing = self.composing;
        const epoch = self.session_epoch;
        const ingress = self.message_epoch;
        self.cancelLocal(.{ .context = window, .emit = emitWindow });
        if (!force_native and !was_composing) return;
        if (window.phase != .open or window.native.hwnd != hwnd or window.native.identity != identity) return error.Closed;
        const current = if (window.text_client) |value| value.context else null;
        // A cancel callback can install another client or start another IME
        // session. The old operation must not cancel that new authority.
        if (window.text_generation != generation or current != client or self.composing or self.session_epoch != epoch or self.message_epoch != ingress) return;
        try cancelComposition(hwnd);
        // No local cleanup follows IMM: its synchronous callbacks may have
        // already installed a new composition, decoder unit or native offer.
    }
    /// Complete one old composition locally. Repeated END/cancel messages do
    /// not repeat its notification, and callback-created state survives.
    pub fn cancelLocal(self: *Handler, sink: Sink) void {
        const was_composing = self.composing;
        self.composing = false;
        self.high_surrogate = null;
        self.reconversion = null;
        self.continuation_epoch +|= 1;
        if (was_composing) sink.emit(sink.context, .text_preedit_cancel);
    }
    /// Fallible entry for adapters and message-level tests. Null preserves the
    /// normal native handling path, including focus cancellation and Tab.
    pub fn processTo(self: *Handler, sink: Sink, hwnd: ?*anyopaque, message: u32, wp: usize, lp: isize) InputError!?isize {
        if (self.blocksServiceMessage(message)) return 0;
        try self.beginMessage(message, wp, lp);
        return self.processCurrent(sink, hwnd, message, wp, lp);
    }
    /// Both native and caller-owned seams enter once before taking their guard.
    /// Native cancellation END/empty notifications are cleanup, not new input.
    fn beginMessage(self: *Handler, message: u32, wp: usize, lp: isize) InputError!void {
        if (self.continuation_epoch == std.math.maxInt(u64)) return error.IdExhausted;
        const produces = switch (message) {
            c.WM_CHAR, c.WM_IME_STARTCOMPOSITION => true,
            c.WM_UNICHAR => wp != c.UNICODE_NOCHAR,
            c.WM_IME_COMPOSITION => @as(usize, @bitCast(lp)) & (c.GCS_RESULTSTR | c.GCS_COMPSTR | c.GCS_CURSORPOS) != 0,
            else => false,
        };
        if (produces) self.message_epoch = std.math.add(u64, self.message_epoch, 1) catch return error.IdExhausted;
    }
    fn processCurrent(self: *Handler, sink: Sink, hwnd: ?*anyopaque, message: u32, wp: usize, lp: isize) InputError!?isize {
        switch (message) {
            c.WM_CHAR => {
                if (wp > 0xffff) return error.InvalidScalar;
                try self.character(sink, @intCast(wp));
                return 0;
            },
            c.WM_UNICHAR => {
                if (wp == c.UNICODE_NOCHAR) return 1;
                self.high_surrogate = null;
                try self.scalar(sink, wp);
                return 0;
            },
            c.WM_KEYDOWN => {
                const control = c.GetKeyState(c.VK_CONTROL) < 0;
                const shift = c.GetKeyState(c.VK_SHIFT) < 0;
                const key: core.EditKeyCode = switch (wp) {
                    c.VK_LEFT => .left,
                    c.VK_RIGHT => .right,
                    c.VK_UP => .up,
                    c.VK_DOWN => .down,
                    c.VK_HOME => .home,
                    c.VK_END => .end,
                    c.VK_BACK => .backspace,
                    c.VK_DELETE => .delete,
                    'A' => if (control) .a else return null,
                    'C' => if (control) .c else return null,
                    'X' => if (control) .x else return null,
                    'V' => if (control) .v else return null,
                    'Z' => if (control) .z else return null,
                    'Y' => if (control) .y else return null,
                    else => return null,
                };
                // Navigation belongs to an active IME while it is composing.
                if (self.composing) return null;
                sink.emit(sink.context, .{ .edit_key = .{ .key = key, .control = control, .shift = shift } });
                return 0;
            },
            c.WM_IME_SETCONTEXT => {
                if (wp == 0) return null;
                const native: c.HWND = @ptrCast(hwnd);
                if (native == null) return error.InvalidWindow;
                const flags: usize = @bitCast(lp);
                const filtered = flags & ~@as(usize, c.ISC_SHOWUICOMPOSITIONWINDOW);
                return c.DefWindowProcW(native, message, wp, @bitCast(filtered));
            },
            c.WM_IME_STARTCOMPOSITION => {
                self.high_surrogate = null;
                self.session_epoch = std.math.add(u64, self.session_epoch, 1) catch return error.IdExhausted;
                self.composing = true;
                return 0;
            },
            c.WM_IME_COMPOSITION => return self.processComposition(sink, hwnd, @bitCast(lp)),
            // DefWindowProc would translate this to WM_CHAR, duplicating result
            // text already delivered from WM_IME_COMPOSITION above.
            c.WM_IME_CHAR => return 0,
            c.WM_IME_ENDCOMPOSITION => {
                self.cancelLocal(sink);
                return 0;
            },
            c.WM_KILLFOCUS => {
                const was_composing = self.composing;
                self.cancelLocal(sink);
                // Native process() uses the checked Window entry above. This
                // message-only seam remains useful with caller-owned sinks.
                if (was_composing and !self.composing) {
                    try cancelComposition(hwnd);
                }
                return null;
            },
            else => return null,
        }
    }
    fn blocksServiceMessage(self: *const Handler, message: u32) bool {
        if (self.system_enabled and !self.mode_transition) return false;
        return switch (message) {
            c.WM_IME_SETCONTEXT, c.WM_IME_STARTCOMPOSITION, c.WM_IME_COMPOSITION, c.WM_IME_ENDCOMPOSITION, c.WM_IME_CHAR, c.WM_IME_REQUEST => true,
            else => false,
        };
    }
    fn character(self: *Handler, sink: Sink, unit: u16) InputError!void {
        const epoch = self.continuation_epoch;
        const message = self.message_epoch;
        const session = self.session_epoch;
        if (unit >= 0xd800 and unit <= 0xdbff) {
            if (self.high_surrogate != null) {
                // Replacement consumes the old unit before its observer. A
                // revoked tail cannot leave it pending or overwrite new state.
                self.high_surrogate = null;
                try self.scalar(sink, 0xfffd);
            }
            if (!sink.isCurrent() or epoch != self.continuation_epoch or message != self.message_epoch or session != self.session_epoch) return;
            self.high_surrogate = unit;
            return;
        }
        if (self.high_surrogate) |high| {
            self.high_surrogate = null;
            if (unit >= 0xdc00 and unit <= 0xdfff) {
                const value = 0x10000 + (@as(u32, high) - 0xd800) * 1024 + unit - 0xdc00;
                return self.scalar(sink, value);
            }
            try self.scalar(sink, 0xfffd);
            if (!sink.isCurrent() or epoch != self.continuation_epoch or message != self.message_epoch or session != self.session_epoch) return;
        }
        if (unit >= 0xdc00 and unit <= 0xdfff) return self.scalar(sink, 0xfffd);
        if (unit == '\r') return self.scalar(sink, '\n');
        if (unit < 0x20 and unit != '\n' and unit != '\t') return;
        if (unit == 0x7f) return;
        return self.scalar(sink, unit);
    }
    fn scalar(self: *Handler, sink: Sink, value: usize) InputError!void {
        _ = self;
        if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return error.InvalidScalar;
        if ((value < 0x20 and value != '\n' and value != '\t' and value != '\r') or value == 0x7f) return;
        var text: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(@intCast(value), &text) catch return error.InvalidScalar;
        sink.emit(sink.context, .{ .text_input = .{ .text = text[0..count], .producer = .win32_character } });
    }
    // Keep the 20 KiB scratch off every window record and every ordinary key
    // callback's stack. Reentrant native callbacks receive independent storage.
    noinline fn processComposition(self: *Handler, sink: Sink, hwnd: ?*anyopaque, flags: usize) InputError!?isize {
        const epoch = self.continuation_epoch;
        const message = self.message_epoch;
        const session = self.session_epoch;
        const native: c.HWND = @ptrCast(hwnd);
        if (native == null) return error.InvalidWindow;
        const context = c.ImmGetContext(native) orelse return error.InputContextUnavailable;
        defer _ = c.ImmReleaseContext(native, context);
        var wide: [max_composition_units]u16 = undefined;
        var utf8: [max_composition_units * 3]u8 = undefined;
        if (flags & c.GCS_RESULTSTR != 0) {
            const text = try compositionString(context, c.GCS_RESULTSTR, &wide, &utf8);
            self.composing = false;
            sink.emit(sink.context, .{ .text_input = .{ .text = text, .producer = .imm_result } });
            if (!sink.isCurrent() or epoch != self.continuation_epoch or message != self.message_epoch or session != self.session_epoch) return 0;
        }
        if (flags & (c.GCS_COMPSTR | c.GCS_CURSORPOS) != 0) {
            const text = try compositionString(context, c.GCS_COMPSTR, &wide, &utf8);
            const cursor = c.ImmGetCompositionStringW(context, c.GCS_CURSORPOS, null, 0);
            if (cursor < 0) return error.CompositionQueryFailed;
            const selected = try utf8OffsetForUtf16(text, @intCast(cursor));
            if (!self.composing) self.session_epoch = std.math.add(u64, self.session_epoch, 1) catch return error.IdExhausted;
            self.composing = true;
            sink.emit(sink.context, .{ .text_preedit = .{ .text = text, .selection_start = selected, .selection_end = selected } });
        } else if (flags == 0) {
            self.composing = false;
            sink.emit(sink.context, .text_preedit_cancel);
        }
        return 0;
    }
    fn compositionString(context: c.HIMC, kind: c.DWORD, wide: []u16, utf8: []u8) InputError![]const u8 {
        const needed = c.ImmGetCompositionStringW(context, kind, null, 0);
        if (needed < 0) return error.CompositionQueryFailed;
        if (@mod(needed, 2) != 0) return error.InvalidUtf16;
        if (needed > wide.len * 2) return error.CapacityExceeded;
        const copied = c.ImmGetCompositionStringW(context, kind, wide.ptr, @intCast(wide.len * 2));
        if (copied != needed) return error.CompositionChanged;
        const count = std.unicode.utf16LeToUtf8(utf8, wide[0..@intCast(@divTrunc(copied, 2))]) catch return error.InvalidUtf16;
        return utf8[0..count];
    }
};

fn utf8OffsetForUtf16(text: []const u8, requested: usize) InputError!usize {
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    var units: usize = 0;
    while (units < requested) {
        const codepoint = iterator.nextCodepoint() orelse return error.InvalidUtf16;
        units += if (codepoint > 0xffff) @as(usize, 2) else 1;
    }
    if (units != requested) return error.InvalidUtf16;
    return iterator.i;
}

pub fn cancelComposition(hwnd: ?*anyopaque) InputError!void {
    const native: c.HWND = @ptrCast(hwnd);
    if (native == null) return error.InvalidWindow;
    const context = c.ImmGetContext(native) orelse return error.InputContextUnavailable;
    defer _ = c.ImmReleaseContext(native, context);
    if (c.ImmNotifyIME(context, c.NI_COMPOSITIONSTR, c.CPS_CANCEL, 0) == 0) return error.CompositionQueryFailed;
}

/// Candidate geometry is physical pixels in the window's client coordinate space.
pub fn setCaret(hwnd: ?*anyopaque, rect: PixelRect) InputError!void {
    if (rect.width < 0 or rect.height < 0) return error.InvalidGeometry;
    const right = std.math.add(i32, rect.x, rect.width) catch return error.InvalidGeometry;
    const bottom = std.math.add(i32, rect.y, rect.height) catch return error.InvalidGeometry;
    const native: c.HWND = @ptrCast(hwnd);
    if (native == null) return error.InvalidWindow;
    const context = c.ImmGetContext(native) orelse return error.InputContextUnavailable;
    defer _ = c.ImmReleaseContext(native, context);
    var composition = std.mem.zeroes(c.COMPOSITIONFORM);
    composition.dwStyle = c.CFS_POINT;
    composition.ptCurrentPos = .{ .x = rect.x, .y = bottom };
    var candidate = std.mem.zeroes(c.CANDIDATEFORM);
    candidate.dwStyle = c.CFS_EXCLUDE;
    candidate.ptCurrentPos = composition.ptCurrentPos;
    candidate.rcArea = .{ .left = rect.x, .top = rect.y, .right = right, .bottom = bottom };
    if (c.ImmSetCompositionWindow(context, &composition) == 0 or c.ImmSetCandidateWindow(context, &candidate) == 0) return error.CandidatePositionFailed;
}

/// Clipboard allocations occur only for this explicit copy operation. Ownership
/// of the moveable UTF-16 block transfers to Windows only after SetClipboardData.
pub fn writeClipboard(hwnd: ?*anyopaque, text: []const u8) InputError!void {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
    const units = std.unicode.calcUtf16LeLen(text) catch return error.InvalidUtf8;
    const count = std.math.add(usize, units, 1) catch return error.CapacityExceeded;
    const bytes = std.math.mul(usize, count, @sizeOf(u16)) catch return error.CapacityExceeded;
    const memory = c.GlobalAlloc(c.GMEM_MOVEABLE, bytes) orelse return error.ClipboardAllocationFailed;
    var transferred = false;
    defer {
        if (!transferred) _ = c.GlobalFree(memory);
    }
    {
        const pointer = c.GlobalLock(memory) orelse return error.ClipboardAllocationFailed;
        defer _ = c.GlobalUnlock(memory);
        const destination: [*]u16 = @ptrCast(@alignCast(pointer));
        _ = std.unicode.utf8ToUtf16Le(destination[0..units], text) catch return error.InvalidUtf8;
        destination[units] = 0;
    }
    if (c.OpenClipboard(@ptrCast(hwnd)) == 0) return error.ClipboardUnavailable;
    defer _ = c.CloseClipboard();
    if (c.EmptyClipboard() == 0 or c.SetClipboardData(c.CF_UNICODETEXT, memory) == null) return error.ClipboardWriteFailed;
    transferred = true;
}

/// Read into caller-owned bounded UTF-8 storage. No process allocator is used.
pub fn readClipboard(hwnd: ?*anyopaque, destination: []u8) InputError!usize {
    if (c.OpenClipboard(@ptrCast(hwnd)) == 0) return error.ClipboardUnavailable;
    defer _ = c.CloseClipboard();
    const memory = c.GetClipboardData(c.CF_UNICODETEXT) orelse return error.ClipboardUnavailable;
    const bytes = c.GlobalSize(memory);
    if (bytes < 2 or bytes % 2 != 0) return error.ClipboardMalformed;
    const pointer = c.GlobalLock(memory) orelse return error.ClipboardUnavailable;
    defer _ = c.GlobalUnlock(memory);
    const wide: [*]const u16 = @ptrCast(@alignCast(pointer));
    var count: usize = 0;
    while (count < bytes / 2 and wide[count] != 0) : (count += 1) {
        if (count >= destination.len) return error.CapacityExceeded;
    }
    if (count == bytes / 2) return error.ClipboardMalformed;
    var iterator = std.unicode.Utf16LeIterator.init(wide[0..count]);
    var needed: usize = 0;
    while (iterator.nextCodepoint() catch return error.InvalidUtf16) |value| needed += std.unicode.utf8CodepointSequenceLength(value) catch unreachable;
    if (needed > destination.len) return error.CapacityExceeded;
    return std.unicode.utf16LeToUtf8(destination, wide[0..count]) catch return error.InvalidUtf16;
}

test "native text decoder combines surrogate messages and keeps callbacks borrowed" {
    const Probe = struct {
        text: [64]u8 = undefined,
        len: usize = 0,
        canceled: usize = 0,
        fn emit(ptr: *anyopaque, event: core.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (event) {
                .text_input => |input| {
                    @memcpy(self.text[self.len..][0..input.text.len], input.text);
                    self.len += input.text.len;
                    std.debug.assert(input.producer == .win32_character);
                },
                .text_preedit_cancel => self.canceled += 1,
                else => {},
            }
        }
    };
    var probe: Probe = .{};
    var handler: Handler = .{};
    const sink: Sink = .{ .context = &probe, .emit = Probe.emit };
    _ = try handler.processTo(sink, null, c.WM_CHAR, 0xd83d, 0);
    try std.testing.expectEqual(@as(usize, 0), probe.len);
    _ = try handler.processTo(sink, null, c.WM_CHAR, 0xde00, 0);
    _ = try handler.processTo(sink, null, c.WM_UNICHAR, 0x4e2d, 0);
    try std.testing.expectEqualStrings("😀中", probe.text[0..probe.len]);
    try std.testing.expectEqual(@as(?isize, 1), try handler.processTo(sink, null, c.WM_UNICHAR, c.UNICODE_NOCHAR, 0));
    try std.testing.expectError(error.InvalidScalar, handler.processTo(sink, null, c.WM_UNICHAR, 0x110000, 0));
    _ = try handler.processTo(sink, null, c.WM_CHAR, 0xd83d, 0);
    _ = try handler.processTo(sink, null, c.WM_KILLFOCUS, 0, 0);
    try std.testing.expect(handler.high_surrogate == null);
}

test "native composition end revokes old state before a reentrant start" {
    const Probe = struct {
        handler: *Handler,
        cancellations: usize = 0,
        observed_cleared: bool = false,
        fn emit(ptr: *anyopaque, event: core.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (event != .text_preedit_cancel) return;
            self.cancellations += 1;
            self.observed_cleared = !self.handler.composing and self.handler.high_surrogate == null and self.handler.reconversion == null;
            _ = self.handler.processTo(.{ .context = self, .emit = emit }, null, c.WM_IME_STARTCOMPOSITION, 0, 0) catch unreachable;
            self.handler.high_surrogate = 0xd83d;
            self.handler.reconversion = .{ .token = undefined, .revision = 2, .range = .{ .start = 1, .end = 1 }, .hash = 7 };
        }
    };
    var handler: Handler = .{ .composing = true, .high_surrogate = 0xd800, .reconversion = .{ .token = undefined, .revision = 1, .range = .{ .start = 0, .end = 0 }, .hash = 0 } };
    var probe: Probe = .{ .handler = &handler };
    _ = try handler.processTo(.{ .context = &probe, .emit = Probe.emit }, null, c.WM_IME_ENDCOMPOSITION, 0, 0);
    try std.testing.expect(probe.observed_cleared);
    try std.testing.expectEqual(@as(usize, 1), probe.cancellations);
    try std.testing.expect(handler.composing);
    try std.testing.expectEqual(@as(?u16, 0xd83d), handler.high_surrogate);
    try std.testing.expectEqual(@as(u64, 2), handler.reconversion.?.revision);
}
