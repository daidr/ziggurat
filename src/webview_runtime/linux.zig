const std = @import("std");
const c = @cImport({
    @cInclude("dlfcn.h");
});

pub const max_path_bytes = 4095;
pub const max_payload_bytes = 256;
pub const Failure = struct {
    phase: enum { load_loader, find_entry, query_version, read_version, release_loader },
    domain: enum { dynamic_loader, contract },
    /// Dynamic loader errors have no portable numeric code (0). Contract
    /// codes: 1 = null entry without dlerror; 2 = version formatting failure.
    code: u32,
    diagnostic_truncated: bool = false,
};

const Payload = union { version: [max_payload_bytes]u8, diagnostic: [max_payload_bytes]u8 };
pub const Result = struct {
    status: enum { available, runtime_absent, failed },
    failure: ?Failure = null,
    cleanup_failure: ?Failure = null,
    payload: Payload = .{ .version = @splat(0) },
    version_length: u16 = 0,
    diagnostic_length: u16 = 0,
    cleanup_diagnostic_length: u16 = 0,

    pub fn version(self: *const Result) []const u8 {
        return if (self.status == .available) self.payload.version[0..self.version_length] else &.{};
    }
    /// Original loader bytes, not necessarily UTF-8. No borrowed loader memory.
    pub fn diagnostic(self: *const Result) []const u8 {
        return if (self.status == .failed) self.payload.diagnostic[0..self.diagnostic_length] else &.{};
    }
    pub fn cleanupDiagnostic(self: *const Result) []const u8 {
        return if (self.cleanup_failure != null) self.payload.diagnostic[128..][0..self.cleanup_diagnostic_length] else &.{};
    }
};

const Native = struct {
    fn open(_: Native, loader_path: [*:0]const u8) ?*anyopaque {
        return c.dlopen(loader_path, c.RTLD_NOW | c.RTLD_LOCAL);
    }
    fn symbol(_: Native, handle: *anyopaque, name: [*:0]const u8) ?*anyopaque {
        return c.dlsym(handle, name);
    }
    fn errorText(_: Native) ?[*:0]const u8 {
        const value = c.dlerror();
        return if (value == null) null else @ptrCast(value);
    }
    fn close(_: Native, handle: *anyopaque) c_int {
        return c.dlclose(handle);
    }
};

pub noinline fn captureAndProbe(options: anytype) !Result {
    return captureWith(options, Native{});
}

fn checkCancellation(cancellation: anytype) !void {
    if (cancellation) |value| if (value.requested.load(.acquire)) return error.Cancelled;
}

fn path(storage: *[max_path_bytes + 1]u8, input: []const u8) ![:0]const u8 {
    if (input.len > max_path_bytes) return error.PathCapacityExceeded;
    if (input.len == 0) return error.InvalidPath;
    if (input[0] != '/') return error.AbsolutePathRequired;
    if (std.mem.indexOfScalar(u8, input, 0) != null or !std.unicode.utf8ValidateSlice(input)) return error.InvalidPath;
    @memcpy(storage[0..input.len], input);
    storage[input.len] = 0;
    return storage[0..input.len :0];
}

fn captureWith(options: anytype, api: anytype) !Result {
    try checkCancellation(options.cancellation);
    if (options.browser_executable_folder) |folder| if (folder.len != 0) return error.UnsupportedOption;
    var storage: [max_path_bytes + 1]u8 = undefined;
    const captured = try path(&storage, options.loader_path);
    try checkCancellation(options.cancellation);
    _ = api.errorText();
    const handle = api.open(captured.ptr) orelse {
        const failure = loaderFailure(.load_loader, api.errorText());
        try checkCancellation(options.cancellation);
        return failure;
    };
    // Keep the error union until the one acquired reference has been released.
    // There is no retry, cache, allocator or escape path around this close.
    const queried = query(handle, options.cancellation, api);
    _ = api.errorText();
    const closed = api.close(handle);
    if (closed != 0) {
        const text = api.errorText();
        if (queried) |value| {
            var result = value;
            if (result.status == .failed) {
                addCleanupFailure(&result, text);
                return result;
            }
        } else |_| {}
        // A failed release must remain observable even when cancellation won
        // the query. Cancelled alone would hide an unreleased native reference.
        return loaderFailure(.release_loader, text);
    }
    try checkCancellation(options.cancellation);
    return queried;
}

fn query(handle: *anyopaque, cancellation: anytype, api: anytype) !Result {
    const names = [_][*:0]const u8{ "webkit_get_major_version", "webkit_get_minor_version", "webkit_get_micro_version" };
    const Getter = *const fn () callconv(.c) c_uint;
    var getters: [3]Getter = undefined;
    for (names, 0..) |name, index| {
        try checkCancellation(cancellation);
        _ = api.errorText();
        const address = api.symbol(handle, name);
        const text = api.errorText();
        if (text != null) return loaderFailure(.find_entry, text);
        const callable = address orelse return contractFailure(.find_entry, 1);
        getters[index] = @ptrCast(@alignCast(callable));
    }
    var values: [3]c_uint = undefined;
    for (getters, 0..) |getter, index| {
        try checkCancellation(cancellation);
        values[index] = getter();
    }
    try checkCancellation(cancellation);
    var result: Result = .{ .status = .available };
    const version = std.fmt.bufPrint(&result.payload.version, "{d}.{d}.{d}", .{ values[0], values[1], values[2] }) catch return contractFailure(.read_version, 2);
    result.version_length = @intCast(version.len);
    return result;
}

fn copyDiagnostic(output: []u8, text: ?[*:0]const u8) struct { length: u16, truncated: bool } {
    const value = text orelse return .{ .length = 0, .truncated = false };
    var length: usize = 0;
    while (length < output.len and value[length] != 0) : (length += 1) output[length] = value[length];
    return .{ .length = @intCast(length), .truncated = value[length] != 0 };
}

fn loaderFailure(phase: @FieldType(Failure, "phase"), text: ?[*:0]const u8) Result {
    var result: Result = .{ .status = .failed, .payload = .{ .diagnostic = @splat(0) } };
    const copied = copyDiagnostic(&result.payload.diagnostic, text);
    result.failure = .{ .phase = phase, .domain = .dynamic_loader, .code = 0, .diagnostic_truncated = copied.truncated };
    result.diagnostic_length = copied.length;
    return result;
}

fn contractFailure(phase: @FieldType(Failure, "phase"), code: u32) Result {
    return .{ .status = .failed, .failure = .{ .phase = phase, .domain = .contract, .code = code }, .payload = .{ .diagnostic = @splat(0) } };
}

fn addCleanupFailure(result: *Result, text: ?[*:0]const u8) void {
    if (result.diagnostic_length > 128) {
        result.diagnostic_length = 128;
        result.failure.?.diagnostic_truncated = true;
    }
    const copied = copyDiagnostic(result.payload.diagnostic[128..], text);
    result.cleanup_failure = .{ .phase = .release_loader, .domain = .dynamic_loader, .code = 0, .diagnostic_truncated = copied.truncated };
    result.cleanup_diagnostic_length = copied.length;
}

test "Linux paths capture absolute bounded original bytes" {
    var storage: [max_path_bytes + 1]u8 = undefined;
    try std.testing.expectEqualStrings("/a/库.so.0", try path(&storage, "/a/库.so.0"));
    try std.testing.expectError(error.InvalidPath, path(&storage, ""));
    try std.testing.expectError(error.AbsolutePathRequired, path(&storage, "loader.so"));
    try std.testing.expectError(error.InvalidPath, path(&storage, "/x\x00.so"));
    try std.testing.expectError(error.InvalidPath, path(&storage, "/\xff.so"));
    const unreadable: [*]const u8 = @ptrFromInt(4096);
    try std.testing.expectError(error.PathCapacityExceeded, path(&storage, unreadable[0 .. max_path_bytes + 1]));
    var maximum: [max_path_bytes]u8 = @splat('x');
    maximum[0] = '/';
    const captured = try path(&storage, &maximum);
    try std.testing.expect(captured.len == max_path_bytes and captured[max_path_bytes] == 0);
}

test "Linux diagnostics own raw bytes and share one payload on cleanup failure" {
    const exact: [256:0]u8 = @splat('a');
    const exact_result = loaderFailure(.load_loader, &exact);
    try std.testing.expect(exact_result.diagnostic().len == 256 and !exact_result.failure.?.diagnostic_truncated);
    const raw: [300:0]u8 = @splat(0xff);
    var result = loaderFailure(.find_entry, &raw);
    const copy = result;
    @memset(&result.payload.diagnostic, 0);
    try std.testing.expect(copy.version().len == 0 and copy.diagnostic().len == 256);
    try std.testing.expect(copy.failure.?.diagnostic_truncated and copy.failure.?.domain == .dynamic_loader);
    try std.testing.expect(copy.diagnostic()[0] == 0xff);
    result = copy;
    addCleanupFailure(&result, &raw);
    try std.testing.expect(result.diagnostic().len == 128 and result.cleanupDiagnostic().len == 128);
    try std.testing.expect(result.failure.?.phase == .find_entry and result.cleanup_failure.?.phase == .release_loader);
    try std.testing.expect(result.failure.?.diagnostic_truncated and result.cleanup_failure.?.diagnostic_truncated);
}

const TestCancellation = struct { requested: std.atomic.Value(bool) = .init(false) };
const TestOptions = struct {
    loader_path: []const u8 = "/test.so",
    browser_executable_folder: ?[]const u8 = null,
    cancellation: ?*const TestCancellation = null,
};
const Faults = struct {
    var getter_calls: usize = 0;
    pending: ?[*:0]const u8 = "stale error",
    missing: ?usize = null,
    null_entry: ?usize = null,
    open_fails: bool = false,
    close_fails: bool = false,
    opens: usize = 0,
    symbols: usize = 0,
    closes: usize = 0,
    cancel: ?*TestCancellation = null,
    cancel_at: enum { none, open, symbol, close } = .none,

    fn getter() callconv(.c) c_uint {
        getter_calls += 1;
        return std.math.maxInt(c_uint);
    }
    fn trigger(self: *Faults, at: @FieldType(Faults, "cancel_at")) void {
        if (self.cancel_at == at) self.cancel.?.requested.store(true, .release);
    }
    fn open(self: *Faults, _: [*:0]const u8) ?*anyopaque {
        std.debug.assert(self.pending == null);
        self.opens += 1;
        self.trigger(.open);
        self.pending = if (self.open_fails) "open raw \xff" else "stale after open";
        return if (self.open_fails) null else @ptrFromInt(4096);
    }
    fn symbol(self: *Faults, _: *anyopaque, _: [*:0]const u8) ?*anyopaque {
        std.debug.assert(self.pending == null);
        const at = self.symbols;
        self.symbols += 1;
        self.trigger(.symbol);
        if (self.missing == at) {
            self.pending = "symbol raw \xfe";
            return null;
        }
        return if (self.null_entry == at) null else @ptrCast(@constCast(&getter));
    }
    fn errorText(self: *Faults) ?[*:0]const u8 {
        const value = self.pending;
        self.pending = null;
        return value;
    }
    fn close(self: *Faults, _: *anyopaque) c_int {
        std.debug.assert(self.pending == null);
        self.closes += 1;
        self.trigger(.close);
        self.pending = if (self.close_fails) "close raw \xfd" else null;
        return if (self.close_fails) -1 else 0;
    }
};

test "Linux lookup checks dlerror and resolves every entry before invoking any getter" {
    for (0..3) |missing| {
        Faults.getter_calls = 0;
        var api: Faults = .{ .missing = missing };
        const result = try captureWith(TestOptions{}, &api);
        try std.testing.expect(result.status == .failed and result.failure.?.phase == .find_entry);
        try std.testing.expectEqualStrings("symbol raw \xfe", result.diagnostic());
        try std.testing.expect(api.symbols == missing + 1 and api.closes == 1 and Faults.getter_calls == 0);
    }
    var null_api: Faults = .{ .null_entry = 0 };
    const null_result = try captureWith(TestOptions{}, &null_api);
    try std.testing.expect(null_result.failure.?.domain == .contract and null_result.failure.?.code == 1);
    try std.testing.expect(null_api.closes == 1);
    var good: Faults = .{};
    Faults.getter_calls = 0;
    const result = try captureWith(TestOptions{}, &good);
    try std.testing.expectEqualStrings("4294967295.4294967295.4294967295", result.version());
    try std.testing.expect(result.diagnostic().len == 0 and good.closes == 1 and Faults.getter_calls == 3);
}

test "Linux load and cleanup failures retain raw domains phases and both diagnostics" {
    var missing: Faults = .{ .open_fails = true };
    const load = try captureWith(TestOptions{}, &missing);
    try std.testing.expect(load.status == .failed and load.failure.?.phase == .load_loader and load.failure.?.domain == .dynamic_loader);
    try std.testing.expectEqualStrings("open raw \xff", load.diagnostic());
    try std.testing.expect(missing.opens == 1 and missing.closes == 0);
    var closing: Faults = .{ .close_fails = true };
    const close = try captureWith(TestOptions{}, &closing);
    try std.testing.expect(close.status == .failed and close.failure.?.phase == .release_loader and close.cleanup_failure == null);
    try std.testing.expectEqualStrings("close raw \xfd", close.diagnostic());
    try std.testing.expect(closing.closes == 1);
    var both: Faults = .{ .missing = 2, .close_fails = true };
    const result = try captureWith(TestOptions{}, &both);
    try std.testing.expect(result.failure.?.phase == .find_entry and result.cleanup_failure.?.phase == .release_loader);
    try std.testing.expectEqualStrings("symbol raw \xfe", result.diagnostic());
    try std.testing.expectEqualStrings("close raw \xfd", result.cleanupDiagnostic());
    try std.testing.expect(both.closes == 1);
}

test "Linux preflight rejects forbidden inputs before capture or loader ownership" {
    const unreadable: [*]const u8 = @ptrFromInt(4096);
    var cancelled: TestCancellation = .{};
    cancelled.requested.store(true, .release);
    var api: Faults = .{};
    try std.testing.expectError(error.Cancelled, captureWith(TestOptions{ .loader_path = unreadable[0..1], .cancellation = &cancelled }, &api));
    try std.testing.expectError(error.UnsupportedOption, captureWith(TestOptions{ .loader_path = unreadable[0..1], .browser_executable_folder = unreadable[0..1] }, &api));
    try std.testing.expectError(error.PathCapacityExceeded, captureWith(TestOptions{ .loader_path = unreadable[0 .. max_path_bytes + 1] }, &api));
    try std.testing.expect(api.opens == 0 and api.closes == 0);
}

test "Linux cancellation always attempts one close and never hides a release failure" {
    const points = [_]@FieldType(Faults, "cancel_at"){ .open, .symbol, .close };
    for (points) |point| {
        var cancel: TestCancellation = .{};
        var api: Faults = .{ .cancel = &cancel, .cancel_at = point };
        try std.testing.expectError(error.Cancelled, captureWith(TestOptions{ .cancellation = &cancel }, &api));
        try std.testing.expect(api.opens == 1 and api.closes == 1);
        cancel.requested.store(false, .release);
        api = .{ .cancel = &cancel, .cancel_at = point, .close_fails = true };
        const result = try captureWith(TestOptions{ .cancellation = &cancel }, &api);
        try std.testing.expect(result.status == .failed and result.failure.?.phase == .release_loader);
        try std.testing.expectEqualStrings("close raw \xfd", result.diagnostic());
        try std.testing.expect(api.closes == 1);
    }
}
