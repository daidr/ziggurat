const std = @import("std");
const runtime = @import("ziggurat_webview_runtime");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("dlfcn.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

const Probe = struct {
    main_thread: std.Thread.Id,
    options: runtime.Options,
    worker_thread: std.Thread.Id = undefined,
    failure: ?anyerror = null,
    result: ?runtime.Result = null,
    fn run(self: *Probe) void {
        self.worker_thread = std.Thread.getCurrentId();
        self.result = runtime.probe(self.main_thread, self.options) catch |err| {
            self.failure = err;
            return;
        };
    }
    fn finish(self: *Probe, thread: std.Thread) !runtime.Result {
        thread.join();
        if (self.failure) |err| return err;
        return self.result.?;
    }
};

fn run(main_thread: std.Thread.Id, options: runtime.Options) !runtime.Result {
    var probe: Probe = .{ .main_thread = main_thread, .options = options };
    const worker = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    return probe.finish(worker);
}

fn resetLog(path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    file.close();
}

fn expectLog(path: []const u8, expected: []const u8) !void {
    var storage: [1024]u8 = undefined;
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const length = try file.readAll(&storage);
    try std.testing.expectEqualStrings(expected, storage[0..length]);
}

fn zPath(storage: []u8, path: []const u8) ![:0]const u8 {
    if (path.len + 1 > storage.len) return error.PathCapacityExceeded;
    @memcpy(storage[0..path.len], path);
    storage[path.len] = 0;
    return storage[0..path.len :0];
}

fn heldReference(main_thread: std.Thread.Id, fixture: []const u8, log: []const u8) !void {
    try resetLog(log);
    var path_storage: [4096]u8 = undefined;
    const path = try zPath(&path_storage, fixture);
    _ = c.dlerror();
    const library = c.dlopen(path.ptr, c.RTLD_NOW | c.RTLD_LOCAL) orelse return error.FixtureLoadFailed;
    var held = true;
    defer {
        if (held) _ = c.dlclose(library);
    }
    _ = c.dlerror();
    const symbol = c.dlsym(library, "ziggurat_runtime_fixture_counts");
    try std.testing.expect(c.dlerror() == null and symbol != null);
    const counts: *const fn (*[3]c_uint, *u64) callconv(.c) void = @ptrCast(@alignCast(symbol.?));
    var probe: Probe = .{ .main_thread = main_thread, .options = .{ .loader_path = fixture, .browser_executable_folder = "" } };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    const result = try probe.finish(thread);
    try std.testing.expectEqualStrings("7.41.923", result.version());
    try expectLog(log, "Labc");
    var calls: [3]c_uint = undefined;
    var getter_thread: u64 = undefined;
    counts(&calls, &getter_thread);
    try std.testing.expectEqualSlices(c_uint, &.{ 1, 1, 1 }, &calls);
    try std.testing.expect(getter_thread == probe.worker_thread and getter_thread != main_thread);
    try std.testing.expect(c.dlclose(library) == 0);
    held = false;
    try expectLog(log, "LabcD");
    std.debug.print("external-held reference: one constructor, worker getters, final destructor only after external close\n", .{});
}

fn cancelInConstructor(main_thread: std.Thread.Id, fixture: []const u8, log: []const u8) !void {
    try resetLog(log);
    var ready: [2]c_int = undefined;
    var gate_resume: [2]c_int = undefined;
    try std.testing.expect(c.pipe(&ready) == 0);
    defer {
        for (ready) |fd| _ = c.close(fd);
    }
    try std.testing.expect(c.pipe(&gate_resume) == 0);
    defer {
        for (gate_resume) |fd| _ = c.close(fd);
    }
    var gate_storage: [64]u8 = undefined;
    const gate = try std.fmt.bufPrintZ(&gate_storage, "{d}:{d}", .{ ready[1], gate_resume[0] });
    try std.testing.expect(c.setenv("ZIGGURAT_RUNTIME_FIXTURE_GATE", gate.ptr, 1) == 0);
    defer _ = c.unsetenv("ZIGGURAT_RUNTIME_FIXTURE_GATE");
    var cancellation: runtime.Cancellation = .{};
    var probe: Probe = .{ .main_thread = main_thread, .options = .{ .loader_path = fixture, .cancellation = &cancellation } };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    var value: u8 = undefined;
    // No UI/App exists here. The pipes explicitly model an uninterruptible
    // loader call; production probe adds no wait, gate or helper thread.
    const read = c.read(ready[0], &value, 1);
    cancellation.request();
    const released = c.write(gate_resume[1], "C", 1);
    const result = probe.finish(thread);
    try std.testing.expect(read == 1 and value == 'R' and released == 1);
    try std.testing.expectError(error.Cancelled, result);
    try expectLog(log, "LD");
    std.debug.print("cancel inside real DSO constructor: no getters, destructor before Cancelled\n", .{});
}

fn failedPath(main_thread: std.Thread.Id, path: []const u8, truncated: bool) !void {
    var path_storage: [4096]u8 = undefined;
    const captured = try zPath(&path_storage, path);
    _ = c.dlerror();
    const unexpected = c.dlopen(captured.ptr, c.RTLD_NOW | c.RTLD_LOCAL);
    if (unexpected) |library| {
        _ = c.dlclose(library);
        return error.ExpectedNativeLoadFailure;
    }
    const text = c.dlerror();
    try std.testing.expect(text != null);
    var expected: [256]u8 = undefined;
    var length: usize = 0;
    while (length < expected.len and text[length] != 0) : (length += 1) expected[length] = text[length];
    try std.testing.expect((text[length] != 0) == truncated);
    const result = try run(main_thread, .{ .loader_path = path });
    try std.testing.expect(result.status == .failed and result.failure.?.phase == .load_loader);
    try std.testing.expect(result.failure.?.domain == .dynamic_loader and result.failure.?.code == 0);
    try std.testing.expect(result.failure.?.diagnostic_truncated == truncated);
    try std.testing.expectEqualSlices(u8, expected[0..length], result.diagnostic());
    try std.testing.expect(result.version().len == 0 and result.cleanup_failure == null);
}

pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();
    var fixtures: [4][]const u8 = undefined;
    for (&fixtures) |*fixture| fixture.* = args.next() orelse return error.FourFixturePathsRequired;
    var real_library: ?[]const u8 = null;
    var missing_dependency: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--failed-load")) {
            missing_dependency = args.next() orelse return error.FailedLoadPathRequired;
        } else {
            if (real_library != null) return error.UnexpectedArgument;
            real_library = arg;
        }
    }
    const main_thread = std.Thread.getCurrentId();
    const unreadable: [*]const u8 = @ptrFromInt(4096);
    try std.testing.expectError(error.UiThreadForbidden, runtime.probe(main_thread, .{ .loader_path = unreadable[0..1] }));
    var cancelled: runtime.Cancellation = .{};
    cancelled.request();
    try std.testing.expectError(error.Cancelled, run(main_thread, .{ .loader_path = unreadable[0..1], .cancellation = &cancelled }));
    try std.testing.expectError(error.UnsupportedOption, run(main_thread, .{ .loader_path = unreadable[0..1], .browser_executable_folder = unreadable[0..1] }));
    try std.testing.expectError(error.PathCapacityExceeded, run(main_thread, .{ .loader_path = unreadable[0 .. runtime.max_linux_path_bytes + 1] }));
    try std.testing.expectError(error.AbsolutePathRequired, run(main_thread, .{ .loader_path = "loader.so" }));
    try std.testing.expectError(error.InvalidPath, run(main_thread, .{ .loader_path = "/bad\x00.so" }));
    try std.testing.expectError(error.InvalidPath, run(main_thread, .{ .loader_path = "/bad\xff.so" }));

    const allocator = std.heap.page_allocator;
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    var root_storage: [4096]u8 = undefined;
    const template = try std.fmt.bufPrintZ(&root_storage, "{s}/.zig-cache/managed/runtime-linux-author-out/evidence-XXXXXX", .{cwd});
    try std.fs.cwd().makePath(".zig-cache/managed/runtime-linux-author-out");
    const root = c.mkdtemp(template.ptr) orelse return error.PrivateDirectoryFailed;
    var log_storage: [4096]u8 = undefined;
    const log = try std.fmt.bufPrintZ(&log_storage, "{s}/events", .{std.mem.span(root)});
    try resetLog(log);
    try std.testing.expect(c.setenv("ZIGGURAT_RUNTIME_FIXTURE_LOG", log.ptr, 1) == 0);
    defer _ = c.unsetenv("ZIGGURAT_RUNTIME_FIXTURE_LOG");
    for (0..9) |_| {
        var result = try run(main_thread, .{ .loader_path = fixtures[0] });
        try std.testing.expect(result.status == .available and result.failure == null);
        const copy = result;
        @memset(&result.payload.version, 0);
        try std.testing.expectEqualStrings("7.41.923", copy.version());
        try std.testing.expect(copy.diagnostic().len == 0);
    }
    try expectLog(log, "LabcD" ** 9);
    for (fixtures[1..], 0..) |fixture, index| {
        try resetLog(log);
        const result = try run(main_thread, .{ .loader_path = fixture });
        try std.testing.expect(result.status == .failed and result.failure.?.phase == .find_entry);
        try std.testing.expect(result.failure.?.domain == .dynamic_loader and result.diagnostic().len > 0);
        try expectLog(log, "LD");
        std.debug.print("missing getter {d}: native symbol failure, zero getter calls, constructor/destructor\n", .{index});
    }
    try heldReference(main_thread, fixtures[0], log);
    try cancelInConstructor(main_thread, fixtures[0], log);
    var missing_storage: [4096]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_storage, "{s}/absent.so", .{std.mem.span(root)});
    try failedPath(main_thread, missing, false);
    const long_segment = "/" ++ "x" ** 200;
    const long_missing = try std.fmt.bufPrint(&missing_storage, "{s}{s}{s}{s}/absent.so", .{ std.mem.span(root), long_segment, long_segment, long_segment });
    try failedPath(main_thread, long_missing, true);
    try failedPath(main_thread, log, false);
    if (missing_dependency) |path| {
        try failedPath(main_thread, path, false);
        std.debug.print("native missing dependency: failed/load_loader with original diagnostic, never runtime_absent\n", .{});
    }
    if (real_library) |path| {
        const first = try run(main_thread, .{ .loader_path = path });
        if (first.status != .available) {
            std.debug.print("real DSO discovery failed: {any} bytes={any}\n", .{ first.failure, first.diagnostic() });
            return error.RealLibraryVersionRequired;
        }
        for (0..8) |_| {
            const result = try run(main_thread, .{ .loader_path = path });
            try std.testing.expect(result.status == .available and result.failure == null);
            try std.testing.expectEqualStrings(first.version(), result.version());
        }
        std.debug.print("real selected handle version (9 worker probes): {s}; no Runtime initialization claim\n", .{first.version()});
    }
    std.debug.print("Linux runtime discovery: 7 cold guards, 9 owning fixture probes, 3 missing entries, external hold, constructor cancellation, 3 raw loader failures; Result={d}/{d} Failure={d}/{d}; no App/GTK init/Profile/page\n", .{ @sizeOf(runtime.Result), @alignOf(runtime.Result), @sizeOf(runtime.Failure), @alignOf(runtime.Failure) });
}
