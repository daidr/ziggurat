const std = @import("std");
const builtin = @import("builtin");
const win = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};

const linux = if (builtin.os.tag == .linux) @import("linux.zig") else struct {};
pub const implemented = builtin.os.tag == .windows or builtin.os.tag == .linux;
pub const max_linux_path_bytes = 4095;
pub const max_path_units = 32767;
pub const max_version_bytes = 256;
const max_version_units = 512;

pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
    pub fn request(self: *Cancellation) void {
        self.requested.store(true, .release);
    }
    fn check(self: *const Cancellation) !void {
        if (self.requested.load(.acquire)) return error.Cancelled;
    }
};

pub const Options = struct {
    /// Explicit absolute loader DLL (Windows) or DSO (Linux). The target path
    /// is never searched; Linux dependencies follow the host dynamic loader.
    loader_path: []const u8,
    /// Null asks the SDK for its installed engine selection. SDK environment
    /// and policy overrides also apply to an explicit absolute folder.
    /// Linux rejects nonempty folders; null/empty do not select an engine.
    browser_executable_folder: ?[]const u8 = null,
    cancellation: ?*const Cancellation = null,
};

pub const Failure = if (builtin.os.tag == .linux) linux.Failure else WindowsFailure;
const WindowsFailure = struct {
    phase: enum { load_loader, find_entry, query_version, read_version },
    domain: enum { win32, hresult, contract },
    code: u32,
};

/// An owning value; copying/moving it never leaves a pointer into itself.
/// Available reports Windows engine discovery or Linux handle-resolved library
/// version entry results only, never initialization, identity or permission.
pub const Result = if (builtin.os.tag == .linux) linux.Result else WindowsResult;
const WindowsResult = struct {
    status: enum { available, runtime_absent, failed },
    failure: ?WindowsFailure = null,
    version_storage: [max_version_bytes]u8 = @splat(0),
    version_length: u16 = 0,
    pub fn version(self: *const WindowsResult) []const u8 {
        return self.version_storage[0..self.version_length];
    }
};

/// Blocking discovery on a caller-created worker. No App/Window/COM apartment,
/// browser environment, profile, thread, callback or task is created. Native
/// library loading and registry/disk lookup can block and allocate internally;
/// cancellation is cooperative before/after those calls, not an interruption.
/// The caller supplies the actual process-main-thread identity.
pub fn probe(main_thread: std.Thread.Id, options: Options) !Result {
    if (!implemented) return error.UnsupportedCapability;
    if (std.Thread.getCurrentId() == main_thread) return error.UiThreadForbidden;
    if (options.cancellation) |cancel| try cancel.check();
    if (builtin.os.tag == .linux) return linux.captureAndProbe(options);
    const result = try captureAndProbe(options);
    // Both native destructors have returned before final cancellation wins.
    if (options.cancellation) |cancel| try cancel.check();
    return result;
}

noinline fn captureAndProbe(options: Options) !WindowsResult {
    var loader_storage: [max_path_units + 1]u16 = undefined;
    const loader = try path(&loader_storage, options.loader_path);
    if (!std.ascii.endsWithIgnoreCase(options.loader_path, ".dll")) return error.LoaderDllRequired;
    var folder_storage: [max_path_units + 1]u16 = undefined;
    const folder = if (options.browser_executable_folder) |input| (try path(&folder_storage, input)).ptr else null;
    return probeWindows(loader.ptr, folder, options.cancellation);
}

fn path(storage: []u16, input: []const u8) ![:0]const u16 {
    if (input.len == 0 or input.len > max_path_units * 3 or std.mem.indexOfScalar(u8, input, 0) != null or !std.unicode.utf8ValidateSlice(input)) return error.InvalidPath;
    // Drive-rooted and UNC paths only. Root-relative and drive-relative paths
    // depend on process state and are unsuitable for an explicit DLL lookup.
    const drive = input.len >= 3 and std.ascii.isAlphabetic(input[0]) and input[1] == ':' and (input[2] == '\\' or input[2] == '/');
    const unc = input.len >= 5 and input[0] == '\\' and input[1] == '\\' and input[2] != '\\' and input[2] != '.' and input[2] != '?';
    if (!drive and !unc) return error.AbsolutePathRequired;
    const count = std.unicode.calcUtf16LeLen(input) catch return error.InvalidPath;
    if (count > max_path_units or count >= storage.len) return error.PathCapacityExceeded;
    _ = std.unicode.utf8ToUtf16Le(storage[0..count], input) catch return error.InvalidPath;
    storage[count] = 0;
    return storage[0..count :0];
}

fn probeWindows(loader: [*:0]const u16, folder: ?[*:0]const u16, cancellation: ?*const Cancellation) !WindowsResult {
    if (builtin.os.tag != .windows) return error.UnsupportedCapability;
    if (cancellation) |cancel| try cancel.check();
    const module = win.LoadLibraryExW(loader, null, win.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | win.LOAD_LIBRARY_SEARCH_SYSTEM32);
    const load_error = if (module == null) win.GetLastError() else 0;
    if (module == null) {
        if (cancellation) |cancel| try cancel.check();
        return .{ .status = .failed, .failure = .{ .phase = .load_loader, .domain = .win32, .code = load_error } };
    }
    defer _ = win.FreeLibrary(module);
    if (cancellation) |cancel| try cancel.check();
    const address = win.GetProcAddress(module, "GetAvailableCoreWebView2BrowserVersionString") orelse return .{ .status = .failed, .failure = .{ .phase = .find_entry, .domain = .win32, .code = win.ERROR_PROC_NOT_FOUND } };
    const Query = *const fn (?[*:0]const u16, *?[*:0]u16) callconv(.winapi) i32;
    const query: Query = @ptrCast(address);
    var version: ?[*:0]u16 = null;
    const hr = query(folder, &version);
    defer if (version) |value| win.CoTaskMemFree(value);
    if (cancellation) |cancel| try cancel.check();
    if (hr < 0) return queryFailure(hr);
    const value = version orelse return badVersion(1);
    var length: usize = 0;
    while (length < max_version_units and value[length] != 0) : (length += 1) {}
    if (length == max_version_units) return badVersion(2);
    return copyVersion(value[0..length]);
}

fn queryFailure(hr: i32) WindowsResult {
    return .{
        .status = if (@as(u32, @bitCast(hr)) == 0x80070002) .runtime_absent else .failed,
        .failure = .{ .phase = .query_version, .domain = .hresult, .code = @bitCast(hr) },
    };
}

fn badVersion(code: u32) WindowsResult {
    return .{ .status = .failed, .failure = .{ .phase = .read_version, .domain = .contract, .code = code } };
}

fn copyVersion(value: []const u16) WindowsResult {
    if (value.len == 0) return badVersion(1);
    var result: WindowsResult = .{ .status = .available };
    var iterator = std.unicode.Utf16LeIterator.init(value);
    var bytes: usize = 0;
    while (iterator.nextCodepoint() catch return badVersion(3)) |codepoint| {
        bytes += std.unicode.utf8CodepointSequenceLength(codepoint) catch return badVersion(3);
    }
    if (bytes > max_version_bytes) return badVersion(2);
    const count = std.unicode.utf16LeToUtf8(&result.version_storage, value) catch return badVersion(3);
    result.version_length = @intCast(count);
    return result;
}

test "probe rejects UI or unsupported platform before reading caller paths" {
    const unreadable: [*]const u8 = @ptrFromInt(4096);
    try std.testing.expectError(if (implemented) error.UiThreadForbidden else error.UnsupportedCapability, probe(std.Thread.getCurrentId(), .{ .loader_path = unreadable[0..1] }));
}

test "discovery paths are explicit bounded Windows paths" {
    var storage: [64]u16 = undefined;
    const converted = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, try path(&storage, "C:/engine/loader.dll"));
    defer std.testing.allocator.free(converted);
    try std.testing.expectEqualStrings("C:/engine/loader.dll", converted);
    try std.testing.expectError(error.AbsolutePathRequired, path(&storage, "loader.dll"));
    try std.testing.expectError(error.AbsolutePathRequired, path(&storage, "C:loader.dll"));
    try std.testing.expectError(error.AbsolutePathRequired, path(&storage, "\\loader.dll"));
    try std.testing.expectError(error.AbsolutePathRequired, path(&storage, "\\\\?\\C:\\loader.dll"));
    try std.testing.expectError(error.InvalidPath, path(&storage, "C:/x\x00.dll"));
    try std.testing.expectError(error.InvalidPath, path(&storage, "C:/\xff.dll"));
    try std.testing.expectError(error.PathCapacityExceeded, path(storage[0..3], "C:/long.dll"));
}

test "version is owned across result copies and rejects malformed or oversized output" {
    var original = copyVersion(std.unicode.utf8ToUtf16LeStringLiteral("141.0.1.2 Beta"));
    const copy = original;
    @memset(&original.version_storage, 0);
    try std.testing.expectEqualStrings("141.0.1.2 Beta", copy.version());
    try std.testing.expect(copy.failure == null and copy.status == .available);
    try std.testing.expect(copyVersion(&.{}).status == .failed);
    try std.testing.expect(copyVersion(&.{0xd800}).failure.?.code == 3);
    try std.testing.expect(copyVersion(&(@as([257]u16, @splat('1')))).failure.?.code == 2);
}

test "only SDK engine-not-found means runtime absent; native failures retain their phase and code" {
    const absent = queryFailure(@bitCast(@as(u32, 0x80070002)));
    try std.testing.expect(absent.status == .runtime_absent and absent.failure.?.code == 0x80070002 and absent.failure.?.phase == .query_version);
    const denied = queryFailure(@bitCast(@as(u32, 0x80070005)));
    try std.testing.expect(denied.status == .failed and denied.failure.?.domain == .hresult and denied.failure.?.code == 0x80070005);
    const unknown = queryFailure(@bitCast(@as(u32, 0x80004005)));
    try std.testing.expect(unknown.status == .failed and unknown.failure.?.code == 0x80004005);
}
