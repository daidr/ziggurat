//! Production Picker result handling with a native ABI test double. No system
//! dialog is opened; hidden windows and one-shot kernel events drive completion.
const std = @import("std");
const z = @import("ziggurat");
const picker_api = @import("picker_api");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @import("ziggurat_c_win32");
const Filter = extern struct { text: [*]const u16, length: u32 };
const Path = []const u16;
const Driver = struct {
    paths: []const Path,
    event: c.HANDLE = null,
    live: bool = false,
    count: ?u32 = null,
    hr: i32 = 0,
    cancelled: bool = false,
    on_collect: ?*const fn (*Driver) void = null,
    on_close: ?*const fn (*Driver) void = null,
    probe: ?*Probe = null,
    next: ?*Driver = null,
};
var creation_driver: ?*Driver = null;
var native_count: u32 = 0;
var closed_path_calls: usize = 0;

export fn zfp_create(_: ?*anyopaque, _: u32, _: [*]const Filter, _: u32, _: [*]const u16, _: u32, hr: *i32, event: *?*anyopaque) ?*anyopaque {
    const driver = creation_driver.?;
    std.debug.assert(!driver.live);
    driver.event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
    if (driver.event == null) {
        hr.* = @bitCast(@as(u32, 0x8007000e));
        return null;
    }
    driver.live = true;
    native_count += 1;
    hr.* = 0;
    event.* = driver.event;
    return driver;
}
export fn zfp_start(ptr: *anyopaque) i32 {
    const driver: *Driver = @ptrCast(@alignCast(ptr));
    std.debug.assert(c.SetEvent(driver.event) != 0);
    return 0;
}
export fn zfp_cancel(_: *anyopaque) i32 {
    return 0;
}
export fn zfp_collect(ptr: *anyopaque, count: *u32, cancelled: *c_int) i32 {
    const driver: *Driver = @ptrCast(@alignCast(ptr));
    std.debug.assert(driver.live);
    if (driver.on_collect) |hook| hook(driver);
    count.* = driver.count orelse @intCast(driver.paths.len);
    cancelled.* = @intFromBool(driver.cancelled);
    return driver.hr;
}
export fn zfp_path(ptr: *anyopaque, index: u32, path: *?[*]const u16, length: *u32) void {
    const driver: *Driver = @ptrCast(@alignCast(ptr));
    if (!driver.live) closed_path_calls += 1;
    const value = driver.paths[index];
    path.* = value.ptr;
    length.* = @intCast(value.len);
}
export fn zfp_close(ptr: *anyopaque) void {
    const driver: *Driver = @ptrCast(@alignCast(ptr));
    std.debug.assert(driver.live);
    driver.live = false;
    native_count -= 1;
    std.debug.assert(c.CloseHandle(driver.event) != 0);
    driver.event = null;
    if (driver.on_close) |hook| hook(driver);
}
export fn zfp_resource_count() u32 {
    return native_count;
}

const Expected = union(enum) { selected: []const u8, multiple: []const []const u8, failure: anyerror, cancelled };
const Counts = struct { callbacks: usize = 0, closed: usize = 0, inside_close: bool = false, freed: bool = false, failed: bool = false };
const Probe = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    window: z.Window,
    picker: picker_api.Picker = .{},
    bytes: [256]u8 = @splat(0xaa),
    counts: *Counts,
    expected: Expected,

    fn check(self: *Probe, value: picker_api.Result) !void {
        try std.testing.expect(self.picker.native == null and self.picker.context == null and self.picker.window == null and self.picker.wait == null);
        switch (self.expected) {
            .selected => |expected| switch (value) {
                .selected => |actual| try std.testing.expectEqualStrings(expected, actual),
                else => return error.ExpectedSelected,
            },
            .multiple => |expected| switch (value) {
                .selected_multiple => |actual| {
                    try std.testing.expectEqual(expected.len, actual.len);
                    var offset: usize = 0;
                    for (actual, expected) |path, wanted| {
                        try std.testing.expectEqualStrings(wanted, path);
                        try std.testing.expect(path.ptr == self.bytes[offset..].ptr);
                        offset += path.len;
                    }
                },
                else => return error.ExpectedMultiple,
            },
            .failure => |wanted| {
                switch (value) {
                    .failed => |failure| try std.testing.expectEqual(wanted, failure.err),
                    else => return error.ExpectedFailure,
                }
                for (self.bytes) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
            },
            .cancelled => {
                try std.testing.expect(value == .cancelled);
                for (self.bytes) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
            },
        }
    }
    fn result(ptr: *anyopaque, window: z.Window, value: picker_api.Result) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.counts.callbacks += 1;
        self.check(value) catch |err| {
            std.debug.print("picker result check failed: {s}\n", .{@errorName(err)});
            self.counts.failed = true;
        };
        _ = window.destroy() catch {
            self.counts.failed = true;
            self.app.quit();
        };
        // Completion must not touch Picker, its destination or callback context
        // after returning from the user's callback.
        self.counts.freed = true;
        self.allocator.destroy(self);
    }
    fn detachDuringCollect(driver: *Driver) void {
        driver.probe.?.picker.detach();
    }
    fn restartDuringClose(driver: *Driver) void {
        const self = driver.probe.?;
        creation_driver = driver.next.?;
        self.picker.start(self.window, .open_file, .{}, &self.bytes, self, result) catch |err| {
            if (err == error.DialogAlreadyPending or err == error.DialogBusy) {
                // A close guard may reject reentry. Retry explicitly through
                // the owner queue after the original native call unwinds.
                self.app.post(.{ .context = self, .call = restartTask }) catch {
                    self.counts.failed = true;
                    self.app.quit();
                };
                return;
            }
            std.debug.print("reentrant picker start: {s}\n", .{@errorName(err)});
            self.counts.failed = true;
            self.app.quit();
        };
    }
    fn restartTask(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.picker.start(self.window, .open_file, .{}, &self.bytes, self, result) catch |err| {
            std.debug.print("deferred picker restart: {s}\n", .{@errorName(err)});
            self.counts.failed = true;
            self.app.quit();
        };
    }
    fn destroyDuringClose(driver: *Driver) void {
        const self = driver.probe.?;
        const counts = self.counts;
        counts.inside_close = true;
        std.debug.assert(c.DestroyWindow(@ptrCast(self.window.nativeHandle())) != 0);
        if (counts.freed) counts.failed = true;
        counts.inside_close = false;
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.counts.closed += 1;
        if (self.counts.inside_close or self.picker.native != null or self.picker.in_native) self.counts.failed = true;
        self.counts.freed = true;
        self.allocator.destroy(self);
    }
    fn silenceDuringClose(driver: *Driver) void {
        const self = driver.probe.?;
        self.picker.detach();
        self.app.post(.{ .context = self, .call = closeTask }) catch {
            self.counts.failed = true;
            self.app.quit();
        };
    }
    fn closeTask(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        _ = self.window.destroy() catch {
            self.counts.failed = true;
            self.app.quit();
        };
    }
};

fn closeDiscardsResult(allocator: std.mem.Allocator) !void {
    var counts: Counts = .{};
    const probe = try allocator.create(Probe);
    defer if (!counts.freed) allocator.destroy(probe);
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .on_closed = .{ .context = probe, .notify = Probe.closed } });
    probe.* = .{ .allocator = allocator, .app = app, .window = window, .counts = &counts, .expected = .cancelled };
    var driver: Driver = .{ .paths = &.{std.unicode.utf8ToUtf16LeStringLiteral("C:\\result.txt")}, .on_close = Probe.silenceDuringClose, .probe = probe };
    creation_driver = &driver;
    try probe.picker.start(window, .open_file, .{}, &probe.bytes, probe, Probe.result);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and !counts.failed and counts.freed);
    try std.testing.expectEqual(0, counts.callbacks);
    try std.testing.expectEqual(1, counts.closed);
    try std.testing.expectEqual(0, picker_api.resourceCount());
}

fn directDetachClose(allocator: std.mem.Allocator) !void {
    var counts: Counts = .{};
    const probe = try allocator.create(Probe);
    defer if (!counts.freed) allocator.destroy(probe);
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .on_closed = .{ .context = probe, .notify = Probe.closed } });
    probe.* = .{ .allocator = allocator, .app = app, .window = window, .counts = &counts, .expected = .cancelled };
    var driver: Driver = .{ .paths = &.{}, .on_close = Probe.destroyDuringClose, .probe = probe };
    creation_driver = &driver;
    try probe.picker.start(window, .open_file, .{}, &probe.bytes, probe, Probe.result);
    probe.picker.detach();
    try std.testing.expect(!counts.freed and !counts.inside_close and !counts.failed);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and !counts.failed and counts.freed);
    try std.testing.expectEqual(0, counts.callbacks);
    try std.testing.expectEqual(1, counts.closed);
    try std.testing.expectEqual(0, picker_api.resourceCount());
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
}

fn exhaustedGeneration(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var picker: picker_api.Picker = .{ .generation = std.math.maxInt(u64) };
    var destination: [10]u8 = undefined;
    var context: u8 = 0;
    try std.testing.expectError(error.OperationGenerationExhausted, picker.start(window, .open_file, .{}, &destination, &context, Probe.result));
    try std.testing.expectEqual(std.math.maxInt(u64), picker.generation);
    try std.testing.expectEqual(0, picker_api.resourceCount());
}

fn run(allocator: std.mem.Allocator, driver: *Driver, kind: picker_api.Kind, capacity: usize, expected: Expected) !void {
    var counts: Counts = .{};
    const probe = try allocator.create(Probe);
    defer if (!counts.freed) allocator.destroy(probe);
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    probe.* = .{ .allocator = allocator, .app = app, .window = window, .counts = &counts, .expected = expected };
    defer if (!counts.freed) probe.picker.detach();
    driver.probe = probe;
    creation_driver = driver;
    try probe.picker.start(window, kind, .{}, probe.bytes[0..capacity], probe, Probe.result);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (closed_path_calls != 0) std.debug.print("picker accessed closed native path storage {d} times\n", .{closed_path_calls});
    try std.testing.expect(!watchdog.expired and !counts.failed);
    try std.testing.expectEqual(1, counts.callbacks);
    try std.testing.expect(counts.freed);
    try std.testing.expectEqual(0, picker_api.resourceCount());
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
    try std.testing.expectEqual(0, closed_path_calls);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const one: []const Path = &.{std.unicode.utf8ToUtf16LeStringLiteral("C:\\Tools\\alpha.txt")};
    var single: Driver = .{ .paths = one };
    try run(allocator, &single, .open_file, "C:\\Tools\\alpha.txt".len, .{ .selected = "C:\\Tools\\alpha.txt" });
    const many: []const Path = &.{ std.unicode.utf8ToUtf16LeStringLiteral("D:\\文档\\星😀.txt"), std.unicode.utf8ToUtf16LeStringLiteral("C:\\two.txt") };
    const wanted: []const []const u8 = &.{ "D:\\文档\\星😀.txt", "C:\\two.txt" };
    var multiple: Driver = .{ .paths = many };
    try run(allocator, &multiple, .open_files, wanted[0].len + wanted[1].len, .{ .multiple = wanted });
    var too_small: Driver = .{ .paths = many };
    try run(allocator, &too_small, .open_files, wanted[0].len + wanted[1].len - 1, .{ .failure = error.ResultCapacityExceeded });
    const malformed: []const Path = &.{ one[0], &.{0xd800} };
    var invalid: Driver = .{ .paths = malformed };
    try run(allocator, &invalid, .open_files, 256, .{ .failure = error.InvalidUtf16 });
    const missing: []const Path = &.{ one[0], &.{} };
    var non_filesystem: Driver = .{ .paths = missing };
    try run(allocator, &non_filesystem, .open_files, 256, .{ .failure = error.NonFilesystemSelection });
    var invalid_count: Driver = .{ .paths = one, .count = 129 };
    try run(allocator, &invalid_count, .open_files, 256, .{ .failure = error.InvalidResultCount });
    var cancelled: Driver = .{ .paths = &.{}, .cancelled = true };
    try run(allocator, &cancelled, .save_file, 256, .cancelled);
    var failed: Driver = .{ .paths = &.{}, .hr = @bitCast(@as(u32, 0x80004005)) };
    try run(allocator, &failed, .folder, 256, .{ .failure = error.FilePickerResultFailed });
    var replacement: Driver = .{ .paths = one };
    var reentrant: Driver = .{ .paths = many, .on_collect = Probe.detachDuringCollect, .on_close = Probe.restartDuringClose, .next = &replacement };
    try run(allocator, &reentrant, .open_files, 256, .{ .selected = "C:\\Tools\\alpha.txt" });
    try directDetachClose(allocator);
    try closeDiscardsResult(allocator);
    try exhaustedGeneration(allocator);
    std.debug.print("picker result smoke passed: UTF16 surrogate pairs, multi-select, exact capacity, transactional failures, self-freeing callback, reentrant detach/restart, direct detach/raw close and generation exhaustion; native=0\n", .{});
}
