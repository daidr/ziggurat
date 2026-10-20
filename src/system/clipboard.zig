const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const native = if (builtin.is_test) @import("clipboard_unsupported.zig") else if (builtin.os.tag == .windows) @import("clipboard_windows.zig") else if (builtin.os.tag == .linux) @import("clipboard_linux.zig") else @import("clipboard_unsupported.zig");

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

pub const max_formats = 16;
pub const max_name_bytes = 100;
pub const max_files = 1024;
pub const max_entry_bytes = 64 * 1024 * 1024;
pub const max_retry_attempts = 16;
/// Linux native Board/offer/read records still alive, including GTK request
/// callbacks that arrive after cancellation. Other targets report zero.
pub fn resourceCount() u32 {
    if (comptime builtin.is_test or builtin.os.tag != .linux) return 0;
    return native.zsc_resource_count();
}
pub const capabilities = .{
    .board = native.supported,
    .lazy_provider = native.supported,
    .change_events = native.supported,
    // Windows retries a clipboard held open by another process on a native
    // timer. GTK selection transfers have no comparable exclusive lock.
    .busy_retry = native.supported and builtin.os.tag == .windows,
};

/// Byte conventions are identical on every platform. text/html are UTF-8;
/// png is a complete PNG stream; files are absolute UTF-8 paths separated by
/// one NUL byte without a trailing separator; custom is opaque bytes.
pub const Kind = enum(u8) { text, html, png, files, custom };
pub const Format = struct {
    kind: Kind,
    /// Custom only: 1..100 visible ASCII bytes, used as the Windows registered
    /// format name and the GTK selection target, for example "application/x-app".
    name: []const u8 = "",

    pub fn eql(self: Format, other: Format) bool {
        return self.kind == other.kind and (self.kind != .custom or std.mem.eql(u8, self.name, other.name));
    }
};
pub const Entry = struct { format: Format, data: []const u8 };
pub const Available = struct { text: bool = false, html: bool = false, png: bool = false, files: bool = false };
pub const Error = error{ ClipboardBusy, ClipboardMalformed, InvalidUtf16, TooManyFiles, NativeFailure };
pub const Failure = struct { err: Error, code: u32 = 0 };
/// `data` borrows the caller destination. `capacity_exceeded` reports the byte
/// count that would have been written and publishes nothing.
pub const Result = union(enum) {
    data: []const u8,
    formats: Available,
    unavailable,
    capacity_exceeded: usize,
    failed: Failure,
};
pub const Callback = *const fn (*anyopaque, Result) void;
pub const ReadOptions = struct {
    /// Windows only: further attempts after OpenClipboard reports another owner.
    /// Attempts are native timer messages, never a sleep or nested loop.
    attempts: u8 = 4,
    interval_ms: u16 = 25,
};

/// Caller-owned read slot. Keep at a stable address while pending. The result
/// callback runs at most once, on the owner thread, after the slot became idle;
/// it may start another read with the same slot. cancel, Board.deinit and App
/// stop release the slot without a callback.
pub const Request = struct {
    board: ?*Board = null,
    query: Query = .{ .read = .{ .kind = .text } },
    name: [max_name_bytes]u8 = undefined,
    destination: []u8 = &.{},
    context: *anyopaque = undefined,
    on_result: Callback = undefined,
    options: ReadOptions = .{},
    attempts: u8 = 0,
    previous: ?*Request = null,
    next: ?*Request = null,
    native: native.RequestState = .{},

    pub const Query = union(enum) { read: Format, formats };

    pub fn pending(self: *const Request) bool {
        return self.board != null;
    }
    pub fn format(self: *const Request) Format {
        var value = self.query.read;
        if (value.kind == .custom) value.name = self.name[0..value.name.len];
        return value;
    }
    /// Idempotent. No callback follows; the destination is released at return.
    pub fn cancel(self: *Request) void {
        const board = self.board orelse return;
        board.app.assertOwner();
        native.cancel(board, self);
        board.unlink(self);
    }
};

/// Writes one rendered format from a Provider. Data is validated and copied
/// into native storage before return; the slice is only borrowed.
pub const Sink = struct {
    format: Format,
    native: *anyopaque,
    written: bool = false,

    pub fn set(self: *Sink, data: []const u8) !void {
        if (self.written) return error.AlreadyWritten;
        try validateData(self.format.kind, data);
        try native.sinkSet(self, data);
        self.written = true;
    }
};

/// Lazy data for formats announced by Board.offer. render runs on the owner
/// thread when another reader requests a format; failure or no Sink.set leaves
/// that format empty for that reader. released runs once when the offer ends:
/// another owner took the clipboard, a write/offer/revoke replaced it, or the
/// Board stopped. context stays valid until released has returned.
pub const Provider = struct {
    context: *anyopaque,
    render: *const fn (*anyopaque, Format, *Sink) anyerror!void,
    released: ?*const fn (*anyopaque) void = null,
};
pub const BoardOptions = struct {
    context: ?*anyopaque = null,
    /// Any clipboard owner change, including this Board's own writes. Query
    /// again with a Request; no content is attached to the notification.
    on_changed: ?*const fn (*anyopaque) void = null,
    /// Windows renders every still-offered format when the Board stops so data
    /// survives the process. False empties an offer this Board still owns.
    render_on_stop: bool = true,
};

/// One system clipboard connection for an App. Initialize in place at a stable
/// address, deinit before App.deinit. App stop cancels reads without callbacks
/// and ends any lazy offer. All methods run on the App owner thread; do not call
/// deinit from one of this Board's own callbacks.
pub const Board = struct {
    app: *z.App,
    options: BoardOptions,
    stop_node: z.StopParticipant = undefined,
    stop_token: ?z.StopToken = null,
    first: ?*Request = null,
    last: ?*Request = null,
    provider: ?Provider = null,
    offered: [max_formats]Format = undefined,
    offered_names: [max_formats][max_name_bytes]u8 = undefined,
    offered_count: usize = 0,
    last_error: u32 = 0,
    open: bool = false,
    dispatching: bool = false,
    native: native.BoardState = .{},

    pub fn init(self: *Board, app: *z.App, options: BoardOptions) !void {
        app.assertOwner();
        if (!native.supported) return error.UnsupportedCapability;
        if (options.on_changed != null and options.context == null) return error.ContextRequired;
        self.* = .{ .app = app, .options = options };
        self.stop_node = .{ .context = self, .stop = stopped };
        self.stop_token = try app.registerStop(&self.stop_node);
        errdefer _ = app.cancelStop(self.stop_token.?) catch {};
        try native.open(self);
        self.open = true;
    }
    /// Idempotent. Pending reads end without callbacks; a live offer is released.
    pub fn deinit(self: *Board) void {
        if (!self.open) return;
        self.app.assertOwner();
        std.debug.assert(!self.dispatching);
        if (self.stop_token) |token| _ = self.app.cancelStop(token) catch {};
        self.stop_token = null;
        self.shutdown();
    }
    fn stopped(context: *anyopaque) anyerror!void {
        const self: *Board = @ptrCast(@alignCast(context));
        self.stop_token = null;
        const scope = self.app.beginTeardownCallback();
        defer scope.end();
        self.shutdown();
    }
    fn shutdown(self: *Board) void {
        while (self.first) |request| request.cancel();
        native.close(self, self.options.render_on_stop);
        self.endOffer();
        self.open = false;
    }

    /// Replaces the clipboard with eager entries in one native transaction.
    /// Every entry is validated before the old content is touched. Windows hands
    /// GlobalAlloc blocks to the system; GTK copies entries into native storage
    /// that lives until another owner takes the clipboard or the Board closes.
    /// Busy fails with ClipboardBusy and last_error; retry scheduling is the
    /// caller's explicit choice.
    pub fn write(self: *Board, entries: []const Entry) !void {
        try self.require();
        if (entries.len == 0 or entries.len > max_formats) return error.InvalidEntries;
        for (entries, 0..) |entry, index| {
            try validateFormat(entry.format);
            try validateData(entry.format.kind, entry.data);
            for (entries[0..index]) |earlier| if (earlier.format.eql(entry.format)) return error.DuplicateFormat;
        }
        self.last_error = 0;
        try native.write(self, entries);
        self.endOffer();
    }
    /// Announces formats now and renders them only when requested. The formats
    /// and custom names are copied; the provider context follows Provider rules.
    pub fn offer(self: *Board, provider: Provider, announced: []const Format) !void {
        try self.require();
        if (announced.len == 0 or announced.len > max_formats) return error.InvalidEntries;
        for (announced, 0..) |item, index| {
            try validateFormat(item);
            for (announced[0..index]) |earlier| if (earlier.eql(item)) return error.DuplicateFormat;
        }
        var copied: [max_formats]Format = undefined;
        var names: [max_formats][max_name_bytes]u8 = undefined;
        for (announced, 0..) |item, index| {
            @memcpy(names[index][0..item.name.len], item.name);
            copied[index] = item;
        }
        self.last_error = 0;
        try native.offer(self, copied[0..announced.len]);
        self.endOffer();
        self.provider = provider;
        self.offered_names = names;
        self.offered_count = announced.len;
        for (0..announced.len) |index| {
            self.offered[index] = copied[index];
            self.offered[index].name = self.offered_names[index][0..copied[index].name.len];
        }
    }
    /// Ends a live lazy offer and empties the clipboard if this Board still owns
    /// it. Idempotent; released runs before return when an offer was live.
    pub fn revoke(self: *Board) void {
        if (!self.open) return;
        self.app.assertOwner();
        if (self.provider == null) return;
        native.revoke(self);
        self.endOffer();
    }
    pub fn offering(self: *const Board) bool {
        return self.provider != null;
    }
    /// Starts an asynchronous read. The result never arrives inside this call.
    pub fn read(self: *Board, request: *Request, item: Format, destination: []u8, context: *anyopaque, on_result: Callback, options: ReadOptions) !void {
        try validateFormat(item);
        try self.start(request, .{ .read = item }, destination, context, on_result, options);
    }
    /// Starts an asynchronous query of the standard formats now offered.
    pub fn formats(self: *Board, request: *Request, context: *anyopaque, on_result: Callback) !void {
        try self.start(request, .formats, &.{}, context, on_result, .{});
    }
    fn start(self: *Board, request: *Request, query: Request.Query, destination: []u8, context: *anyopaque, on_result: Callback, options: ReadOptions) !void {
        try self.require();
        if (request.board != null) return error.RequestPending;
        if (options.attempts > max_retry_attempts or options.interval_ms == 0) return error.InvalidOptions;
        request.* = .{ .query = query, .destination = destination, .context = context, .on_result = on_result, .options = options };
        if (query == .read and query.read.kind == .custom) {
            @memcpy(request.name[0..query.read.name.len], query.read.name);
            request.query.read.name = request.name[0..query.read.name.len];
        }
        request.board = self;
        request.previous = self.last;
        if (self.last) |tail| tail.next = request else self.first = request;
        self.last = request;
        native.start(self, request) catch |err| {
            self.unlink(request);
            return err;
        };
    }
    fn require(self: *Board) !void {
        if (!self.open) return error.Closed;
        self.app.assertOwner();
    }
    fn unlink(self: *Board, request: *Request) void {
        if (request.previous) |previous| previous.next = request.next else self.first = request.next;
        if (request.next) |next| next.previous = request.previous else self.last = request.previous;
        request.previous = null;
        request.next = null;
        request.board = null;
    }
    fn endOffer(self: *Board) void {
        const provider = self.provider orelse return;
        self.provider = null;
        self.offered_count = 0;
        if (provider.released) |released| released(provider.context);
    }

    /// Native adapter entry: deliver a result once. The request is idle again
    /// before the callback, so the callback may reuse or abandon it.
    pub fn complete(self: *Board, request: *Request, result: Result) void {
        std.debug.assert(request.board == self);
        self.unlink(request);
        const scope = self.app.beginCallback() orelse return;
        defer scope.end();
        const previous = self.dispatching;
        self.dispatching = true;
        defer self.dispatching = previous;
        request.on_result(request.context, result);
    }
    /// Native adapter entry: copy bytes into the request destination or report
    /// the required size. Nothing is published on capacity failure.
    pub fn completeData(self: *Board, request: *Request, data: []const u8) void {
        if (data.len > request.destination.len) return self.complete(request, .{ .capacity_exceeded = data.len });
        @memcpy(request.destination[0..data.len], data);
        self.complete(request, .{ .data = request.destination[0..data.len] });
    }
    /// Native adapter entry: the system ended this Board's offer.
    pub fn ownershipLost(self: *Board) void {
        if (self.provider == null) return;
        const scope = self.app.beginTeardownCallback();
        defer scope.end();
        self.endOffer();
    }
    /// Native adapter entry: run the provider for one offered format.
    /// teardown permits the final Windows render-all while the App stops.
    pub fn render(self: *Board, index: usize, sink_native: *anyopaque, teardown: bool) bool {
        const provider = self.provider orelse return false;
        if (index >= self.offered_count) return false;
        const scope = if (teardown) self.app.beginTeardownCallback() else self.app.beginCallback() orelse return false;
        defer scope.end();
        var sink: Sink = .{ .format = self.offered[index], .native = sink_native };
        const previous = self.dispatching;
        self.dispatching = true;
        defer self.dispatching = previous;
        provider.render(provider.context, self.offered[index], &sink) catch return false;
        return sink.written;
    }
    pub fn changed(self: *Board) void {
        const callback = self.options.on_changed orelse return;
        const scope = self.app.beginCallback() orelse return;
        defer scope.end();
        const previous = self.dispatching;
        self.dispatching = true;
        defer self.dispatching = previous;
        callback(self.options.context.?);
    }
};

pub fn validateFormat(item: Format) !void {
    if (item.kind != .custom) {
        if (item.name.len != 0) return error.InvalidFormatName;
        return;
    }
    if (item.name.len == 0 or item.name.len > max_name_bytes) return error.InvalidFormatName;
    for (item.name) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidFormatName;
}
pub fn validateData(kind: Kind, data: []const u8) !void {
    if (data.len > max_entry_bytes) return error.EntryTooLarge;
    switch (kind) {
        .text, .html => {
            if (std.mem.indexOfScalar(u8, data, 0) != null) return error.EmbeddedNul;
            if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
        },
        .png => if (data.len < 8 or !std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidPng,
        .files => {
            if (data.len == 0) return error.InvalidPath;
            var count: usize = 0;
            var paths_iterator = paths(data);
            while (paths_iterator.next()) |path| {
                count += 1;
                if (count > max_files) return error.TooManyFiles;
                if (!absolute(path) or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
            }
        },
        .custom => {},
    }
}
fn absolute(path: []const u8) bool {
    if (builtin.os.tag != .windows) return path.len != 0 and path[0] == '/';
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) return true;
    return path.len >= 5 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/') and path[2] != '?' and path[2] != '.';
}

/// Iterates the NUL-separated file list convention. Empty items are returned
/// as empty slices so validation can reject them.
pub const PathIterator = struct {
    data: []const u8,
    index: usize = 0,
    done: bool = false,
    pub fn next(self: *PathIterator) ?[]const u8 {
        if (self.done) return null;
        const rest = self.data[self.index..];
        if (std.mem.indexOfScalar(u8, rest, 0)) |end| {
            self.index += end + 1;
            return rest[0..end];
        }
        self.done = true;
        return rest;
    }
};
pub fn paths(data: []const u8) PathIterator {
    return .{ .data = data, .done = data.len == 0 };
}
/// Builds the NUL-separated file list into caller storage.
pub fn joinPaths(destination: []u8, items: []const []const u8) ![]const u8 {
    var used: usize = 0;
    for (items, 0..) |item, index| {
        const extra = item.len + @intFromBool(index != 0);
        if (extra > destination.len - used) return error.CapacityExceeded;
        if (index != 0) {
            destination[used] = 0;
            used += 1;
        }
        @memcpy(destination[used .. used + item.len], item);
        used += item.len;
    }
    return destination[0..used];
}

test "clipboard data conventions validate before native work" {
    try validateFormat(.{ .kind = .custom, .name = "application/x-ziggurat" });
    try std.testing.expectError(error.InvalidFormatName, validateFormat(.{ .kind = .custom, .name = "has space" }));
    try std.testing.expectError(error.InvalidFormatName, validateFormat(.{ .kind = .custom }));
    try std.testing.expectError(error.InvalidFormatName, validateFormat(.{ .kind = .text, .name = "x" }));
    try std.testing.expectError(error.EmbeddedNul, validateData(.text, "a\x00b"));
    try std.testing.expectError(error.InvalidUtf8, validateData(.html, "\xff"));
    try std.testing.expectError(error.InvalidPng, validateData(.png, "GIF89a"));
    var storage: [64]u8 = undefined;
    const sample = if (builtin.os.tag == .windows) [_][]const u8{ "C:\\a b.txt", "C:\\c" } else [_][]const u8{ "/a b.txt", "/c" };
    const joined = try joinPaths(&storage, &sample);
    try validateData(.files, joined);
    var iterator = paths(joined);
    try std.testing.expectEqualStrings(sample[0], iterator.next().?);
    try std.testing.expectEqualStrings(sample[1], iterator.next().?);
    try std.testing.expectEqual(null, iterator.next());
    try std.testing.expectError(error.InvalidPath, validateData(.files, "relative"));
    try std.testing.expectError(error.InvalidPath, validateData(.files, if (builtin.os.tag == .windows) "C:\\a\x00" else "/a\x00"));
    try std.testing.expectError(error.CapacityExceeded, joinPaths(storage[0..3], &sample));
}
