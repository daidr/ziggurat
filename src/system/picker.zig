const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const Filter = extern struct { text: [*]const u16, length: u32 };
extern fn zfp_create(?*anyopaque, u32, [*]const Filter, u32, [*]const u16, u32, *i32, *?*anyopaque) ?*anyopaque;
extern fn zfp_start(*anyopaque) i32;
extern fn zfp_cancel(*anyopaque) i32;
extern fn zfp_collect(*anyopaque, *u32, *c_int) i32;
extern fn zfp_path(*anyopaque, u32, *?[*]const u16, *u32) void;
extern fn zfp_close(*anyopaque) void;
extern fn zfp_resource_count() u32;

pub const Kind = enum(u32) { open_file, save_file, open_files, folder };
pub const Options = struct {
    /// Up to 16 extensions, each "*" or a leading dot plus an extension.
    /// Strings are copied by WinRT before openFile returns.
    /// Empty selects all files for open/folder and .txt for save.
    extensions: []const []const u8 = &.{},
    suggested_name: []const u8 = "Untitled",
};
pub const Result = union(enum) {
    /// Borrowed caller-owned UTF-8 destination; no trailing NUL is included.
    selected: []const u8,
    /// Slice metadata is borrowed through this callback. Path bytes occupy the
    /// caller's destination contiguously; no string includes a trailing NUL.
    selected_multiple: []const []const u8,
    cancelled,
    failed: struct { err: anyerror, hresult: ?i32 = null },
};
pub const Callback = *const fn (*anyopaque, z.Window, Result) void;

/// Native state can outlive its window while WinRT completes cancellation. It
/// contains no Zig or App pointer. This count excludes the system picker UI.
pub fn resourceCount() u32 {
    if (comptime builtin.os.tag != .windows) return 0;
    return zfp_resource_count();
}

/// One pending selection per owner. The destination and callback context stay
/// valid until completion or Owner detach/on_closed. Detach cancels silently,
/// unregisters the core wait first, and disconnects all future Zig callbacks.
/// Completion handlers only signal their independently owned kernel event;
/// WinRT result access and application callbacks run on the process main thread.
pub const Picker = struct {
    native: ?*anyopaque = null,
    window: ?z.Window = null,
    wait: ?z.NativeWaitToken = null,
    destination: []u8 = &.{},
    context: ?*anyopaque = null,
    on_result: ?Callback = null,
    in_native: bool = false,
    closing: bool = false,
    last_hresult: i32 = 0,
    /// Monotonic identity prevents a reentrant completion from adopting a later
    /// operation even if the native allocator reuses an address.
    generation: u64 = 0,
    kind: Kind = .open_file,
    paths: [128][]const u8 = undefined,

    pub fn start(self: *Picker, window: z.Window, kind: Kind, options: Options, destination: []u8, context: *anyopaque, on_result: Callback) !void {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedCapability;
        window.app.assertOwner();
        if (self.native != null or self.in_native) return error.DialogAlreadyPending;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const extensions: []const []const u8 = if (options.extensions.len != 0) options.extensions else if (kind == .save_file) &.{".txt"} else &.{"*"};
        if (extensions.len > 16) return error.InvalidFileFilters;
        var text: [16][128]u16 = undefined;
        var filters: [16]Filter = undefined;
        for (extensions, 0..) |extension, index| {
            if (extension.len == 0 or (!std.mem.eql(u8, extension, "*") and (extension.len < 2 or extension[0] != '.' or std.mem.indexOfAny(u8, extension, "\\/:;*?\x00") != null))) return error.InvalidFileFilters;
            if (kind == .save_file and std.mem.eql(u8, extension, "*")) return error.InvalidFileFilters;
            const needed = std.unicode.calcUtf16LeLen(extension) catch return error.InvalidUtf8;
            if (needed > text[index].len) return error.FileFilterTooLong;
            _ = std.unicode.utf8ToUtf16Le(text[index][0..needed], extension) catch return error.InvalidUtf8;
            filters[index] = .{ .text = &text[index], .length = @intCast(needed) };
        }
        var suggested_name: [256]u16 = undefined;
        if (std.mem.indexOfAny(u8, options.suggested_name, "\\/:*?\"<>|\x00") != null) return error.InvalidSuggestedName;
        const name_len = std.unicode.calcUtf16LeLen(options.suggested_name) catch return error.InvalidUtf8;
        if (name_len > suggested_name.len) return error.SuggestedNameTooLong;
        _ = std.unicode.utf8ToUtf16Le(suggested_name[0..name_len], options.suggested_name) catch return error.InvalidUtf8;
        if (self.generation == std.math.maxInt(u64)) return error.OperationGenerationExhausted;
        self.generation += 1;
        self.closing = false;
        self.in_native = true;
        defer self.leaveNative();
        var event: ?*anyopaque = null;
        const native = zfp_create(window.nativeHandle(), @backingInt(kind), &filters, @intCast(extensions.len), &suggested_name, @intCast(name_len), &self.last_hresult, &event) orelse return error.FilePickerCreationFailed;
        self.native = native;
        self.window = window;
        self.destination = destination;
        self.context = context;
        self.on_result = on_result;
        self.kind = kind;
        errdefer self.detach();
        if (self.closing or window.isClosed()) return error.Closed;
        self.wait = try window.app.watchNative(event.?, .{ .context = self, .call = complete });
        self.last_hresult = zfp_start(native);
        if (self.last_hresult < 0) return error.FilePickerStartFailed;
        if (self.closing or window.isClosed()) return error.Closed;
    }
    /// Requests normal cancellation; a pending dialog still delivers cancelled
    /// when WinRT signals completion. Detach instead suppresses the callback.
    pub fn cancel(self: *Picker) !void {
        if (comptime builtin.os.tag != .windows) return error.UnsupportedCapability;
        const native = self.native orelse return;
        const window = self.window orelse return;
        window.app.assertOwner();
        if (self.in_native) return error.DialogBusy;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.in_native = true;
        defer self.leaveNative();
        self.last_hresult = zfp_cancel(native);
        if (self.last_hresult < 0) return error.FilePickerCancelFailed;
    }
    pub fn detach(self: *Picker) void {
        const window = self.window;
        if (window) |value| {
            value.app.assertOwner();
            if (self.wait) |token| _ = value.app.unwatchNative(token);
        }
        self.wait = null;
        if (self.in_native) {
            self.closing = true;
            return;
        }
        _ = self.closeNative();
    }
    /// Returns false if a nested detach cancelled delivery while Release was
    /// running. Busy remains set across every native call, including teardown.
    fn closeNative(self: *Picker) bool {
        std.debug.assert(!self.in_native);
        const scope = if (self.window) |window| window.beginCallback() else null;
        defer if (scope) |value| value.end();
        self.in_native = true;
        const native = self.native;
        self.native = null;
        self.window = null;
        self.context = null;
        self.on_result = null;
        self.destination = &.{};
        self.closing = false;
        if (comptime builtin.os.tag == .windows) if (native) |value| zfp_close(value);
        const uninterrupted = !self.closing;
        self.in_native = false;
        self.closing = false;
        return uninterrupted;
    }
    fn leaveNative(self: *Picker) void {
        self.in_native = false;
        if (self.closing) self.detach();
    }
    fn complete(ptr: *anyopaque) void {
        const self: *Picker = @ptrCast(@alignCast(ptr));
        const native = self.native orelse return;
        const generation = self.generation;
        const window = self.window orelse return;
        self.wait = null;
        const scope = window.beginCallback() orelse {
            self.detach();
            return;
        };
        defer scope.end();
        var count: u32 = 0;
        var cancelled: c_int = 0;
        self.in_native = true;
        self.last_hresult = zfp_collect(native, &count, &cancelled);
        self.leaveNative();
        if (self.generation != generation or self.native != native) return;
        const result: Result = if (self.last_hresult < 0)
            .{ .failed = .{ .err = error.FilePickerResultFailed, .hresult = self.last_hresult } }
        else if (cancelled != 0)
            .cancelled
        else result: {
            if (count == 0 or count > self.paths.len) break :result .{ .failed = .{ .err = error.InvalidResultCount } };
            var needed: usize = 0;
            for (0..count) |index| {
                var path: ?[*]const u16 = null;
                var length: u32 = 0;
                zfp_path(native, @intCast(index), &path, &length);
                if (length == 0 or path == null) break :result .{ .failed = .{ .err = error.NonFilesystemSelection } };
                var iterator = std.unicode.Utf16LeIterator.init(path.?[0..length]);
                while (iterator.nextCodepoint() catch break :result .{ .failed = .{ .err = error.InvalidUtf16 } }) |value| needed += std.unicode.utf8CodepointSequenceLength(value) catch unreachable;
            }
            if (needed > self.destination.len) break :result .{ .failed = .{ .err = error.ResultCapacityExceeded } };
            var used: usize = 0;
            for (0..count) |index| {
                var path: ?[*]const u16 = null;
                var length: u32 = 0;
                zfp_path(native, @intCast(index), &path, &length);
                const bytes = std.unicode.utf16LeToUtf8(self.destination[used..], path.?[0..length]) catch unreachable;
                self.paths[index] = self.destination[used..][0..bytes];
                used += bytes;
            }
            break :result if (self.kind == .open_files) .{ .selected_multiple = self.paths[0..count] } else .{ .selected = self.paths[0] };
        };
        const callback = self.on_result.?;
        const context = self.context.?;
        if (!self.closeNative() or self.generation != generation or window.isClosed()) return;
        callback(context, window, result);
    }
};
