const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const files = @import("file_responses");
const stream = @import("ziggurat_file_stream");

extern fn zwk_file_native_test() c_int;
extern fn zwk_file_counts(*u32, *u32, *u32, *u32) void;
extern fn zwk_file_prepare_stream(*anyopaque, *anyopaque, c_int, *?*anyopaque, *c_int) c_int;
extern fn zwk_file_candidate_abort(*anyopaque) void;
extern fn zwk_file_candidate_commit(*anyopaque, c_int, c_int, *?*anyopaque) void;
extern fn zwk_file_budget_create(u32) ?*anyopaque;
extern fn zwk_file_budget_release(*anyopaque) void;
extern fn zwk_file_control_alive(*anyopaque) c_int;

const Native = struct {
    result: c_int = -1,
    fn run(self: *Native) void {
        self.result = zwk_file_native_test();
    }
};
test "socket streams are retryable, bounded, pollable and need no implicit worker" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var native: Native = .{};
    const worker = try std.Thread.spawn(.{}, Native.run, .{&native});
    worker.join();
    try std.testing.expectEqual(@as(c_int, 0), native.result);
}

const WindowWorker = struct {
    main_thread: std.Thread.Id,
    failure: ?anyerror = null,
    fn run(self: *WindowWorker) void {
        self.work() catch |err| {
            self.failure = err;
        };
    }
    fn work(self: *WindowWorker) !void {
        var directory = zio.tmpDir(.{});
        defer directory.cleanup();
        const file = try directory.dir.createFile(zio.io(), "window", .{ .read = true });
        defer file.close(zio.io());
        const bytes = "0123456789abcdefghijklmnopqrst";
        try file.writeStreamingAll(zio.io(), bytes);
        try zio.posix.seekTo(file.handle, 7);
        var code: ?i32 = 91;
        var prepared = try stream.PreparedSource.prepareWindowWithFailure(self.main_thread, file, .{ .offset = 10, .length = 3 }, 1024, &code);
        defer prepared.source.deinit();
        defer prepared.pump.deinit();
        try std.testing.expect(code == null);
        try std.testing.expectEqual(@as(u64, 3), prepared.source.length);
        prepared.source.length = 999; // Public cache cannot change native authority.
        try std.testing.expectEqual(@as(u64, 3), try prepared.source.authoritativeLength());
        try std.testing.expectEqual(@as(u64, 7), try zio.posix.position(file.handle));
        prepared.source.deinit();
        prepared.pump.deinit();
        try std.testing.expectEqualDeep(stream.Counts{}, stream.counts());
        try std.testing.expectError(error.InvalidFileWindow, stream.PreparedSource.prepareWindowWithFailure(self.main_thread, file, .{ .offset = bytes.len + 1, .length = 0 }, 1024, &code));
        try std.testing.expect(code == null);
        try std.testing.expectError(error.InvalidFileWindow, stream.PreparedSource.prepareWindowWithFailure(self.main_thread, file, .{ .offset = std.math.maxInt(u64), .length = 1 }, 1024, &code));
        try std.testing.expect(code == null);
        try std.testing.expectError(error.FileTooLarge, stream.PreparedSource.prepareWindowWithFailure(self.main_thread, file, .{ .offset = 0, .length = 1 }, 1, &code));
        try std.testing.expect(code == null);
        const invalid: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };
        try std.testing.expectError(error.FileStreamFailed, stream.PreparedSource.prepareWindowWithFailure(self.main_thread, invalid, .{ .offset = 0, .length = 0 }, 1024, &code));
        try std.testing.expectEqual(@as(i32, @backingInt(std.posix.E.BADF)), code.?);
        var empty = try stream.PreparedSource.prepareWindow(self.main_thread, file, .{ .offset = bytes.len, .length = 0 }, 1024);
        try std.testing.expectEqual(@as(u64, 0), try empty.source.authoritativeLength());
        empty.source.deinit();
        empty.pump.deinit();
        try std.testing.expectEqualDeep(stream.Counts{}, stream.counts());
    }
};
test "file windows preserve public native length authority and failure codes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var worker: WindowWorker = .{ .main_thread = std.Thread.getCurrentId() };
    const thread = try std.Thread.spawn(.{}, WindowWorker.run, .{&worker});
    thread.join(); // Console test driver, no App or UI event loop is active.
    if (worker.failure) |err| return err;
}

fn expectCounts(physical: u32, controls: u32) !void {
    var p: u32 = 0;
    var c: u32 = 0;
    var b: u32 = 0;
    var s: u32 = 0;
    zwk_file_counts(&p, &c, &b, &s);
    try std.testing.expectEqual(physical, p);
    try std.testing.expectEqual(controls, c);
    try std.testing.expectEqual(@as(u32, 0), b);
    try std.testing.expectEqual(@as(u32, 0), s);
}
const Worker = struct {
    main_thread: std.Thread.Id,
    err: ?anyerror = null,
    fn run(self: *Worker) void {
        self.work() catch |err| {
            self.err = err;
        };
    }
    fn allocationFixture(allocator: std.mem.Allocator, self: *Worker, file: std.Io.File) !void {
        var prepared = try files.OwnedFileResponse.preparePumped(allocator, self.main_thread, file, .{ .mime = "text/plain", .headers = &.{.{ .name = "X-Pump", .value = "owned" }} }, 1024);
        defer prepared.pump.deinit();
        defer prepared.response.deinit();
        try prepared.response.validate(1024);
        try std.testing.expectEqual(@as(u64, 17), prepared.response.length);
        try std.testing.expectEqualStrings("owned", prepared.response.metadata.response.headers[0].value);
    }
    fn work(self: *Worker) !void {
        var directory = zio.tmpDir(.{});
        defer directory.cleanup();
        const file = try directory.dir.createFile(zio.io(), "private", .{ .read = true });
        defer file.close(zio.io());
        try file.writeStreamingAll(zio.io(), "explicit transfer");
        try zio.posix.seekTo(file.handle, 3);
        try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{ self, file });
        try std.testing.expectEqual(@as(u64, 3), try zio.posix.position(file.handle));
        try expectCounts(0, 0);
        var code: ?i32 = 91;
        const invalid: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };
        try std.testing.expectError(error.FileStreamFailed, files.OwnedFileResponse.preparePumpedWithFailure(std.testing.failing_allocator, self.main_thread, invalid, .{}, 1024, &code));
        try std.testing.expectEqual(@as(i32, @backingInt(std.posix.E.BADF)), code.?);
        try std.testing.expectError(error.FileTooLarge, files.OwnedFileResponse.preparePumpedWithFailure(std.testing.failing_allocator, self.main_thread, file, .{}, 1, &code));
        try std.testing.expect(code == null);
        try std.testing.expectError(error.InvalidFileStreamLimit, files.OwnedFileResponse.preparePumpedWithFailure(std.testing.failing_allocator, self.main_thread, file, .{}, 0, &code));
        try std.testing.expect(code == null);
        try std.testing.expectError(error.UnexpectedResponseBody, files.OwnedFileResponse.preparePumped(std.testing.allocator, self.main_thread, file, .{ .status = 204 }, 1024));
        try std.testing.expectError(error.UnsupportedCapability, files.OwnedFileResponse.prepare(std.testing.allocator, self.main_thread, file, .{}, 1024));
        try expectCounts(0, 0);

        var prepared = try files.OwnedFileResponse.preparePumped(std.testing.allocator, self.main_thread, file, .{}, 1024);
        defer prepared.pump.deinit();
        defer prepared.response.deinit();
        const budget = zwk_file_budget_create(1) orelse return error.OutOfMemory;
        var budget_live = true;
        defer if (budget_live) zwk_file_budget_release(budget);
        var candidate: ?*anyopaque = null;
        var native_code: c_int = 0;
        try std.testing.expectEqual(@as(c_int, 0), zwk_file_prepare_stream(prepared.response.native.?, budget, 1, &candidate, &native_code));
        zwk_file_candidate_abort(candidate.?);
        try std.testing.expectEqual(@as(c_int, 0), zwk_file_prepare_stream(prepared.response.native.?, budget, 1, &candidate, &native_code));
        var ticket_native: ?*anyopaque = null;
        zwk_file_candidate_commit(candidate.?, 0, 1, &ticket_native);
        var ticket: files.StreamTicket = .{ .native = ticket_native };
        defer ticket.deinit();
        var copy = try ticket.clone();
        defer copy.deinit();
        // No consumer retains the stream, so final native release cancels the
        // committed pump. A ticket does not keep that stream or its slot alive.
        try std.testing.expectError(error.Cancelled, prepared.pump.pump());
        try std.testing.expectError(error.Busy, prepared.pump.pump());
        prepared.response.deinit();
        prepared.pump.deinit();
        zwk_file_budget_release(budget);
        budget_live = false;
        try expectCounts(0, 1);
        try std.testing.expectEqual(@as(c_int, 0), zwk_file_control_alive(ticket.native.?));
        ticket.cancel();
        copy.cancel();
        ticket.deinit();
        try std.testing.expectError(error.TicketMoved, ticket.clone());
        copy.deinit();
        try expectCounts(0, 0);
        try std.testing.expectError(error.ResponseMoved, prepared.response.validate(1024));
        try std.testing.expectError(error.PumpMoved, prepared.pump.pump());

        var allocator: DeinitAllocator = .{};
        var reentry = try files.OwnedFileResponse.preparePumped(allocator.allocator(), self.main_thread, file, .{}, 1024);
        allocator.response = &reentry.response;
        allocator.armed = true;
        reentry.response.deinit();
        try std.testing.expect(allocator.called and allocator.revoked);
        reentry.pump.deinit();
        try expectCounts(0, 0);
    }
};
const DeinitAllocator = struct {
    response: ?*files.OwnedFileResponse = null,
    armed: bool = false,
    called: bool = false,
    revoked: bool = false,
    fn allocator(self: *DeinitAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        return std.testing.allocator.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *DeinitAllocator = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            self.armed = false;
            self.called = true;
            self.revoked = self.response.?.native == null and self.response.?.metadata.storage == null;
            self.response.?.deinit();
        }
        std.testing.allocator.rawFree(bytes, alignment, ra);
    }
};
test "explicit worker preparation preserves position and rolls back metadata allocation failures" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var state: Worker = .{ .main_thread = std.Thread.getCurrentId() };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&state});
    worker.join();
    if (state.err) |err| return err;
}

const UiGate = struct {
    main_thread: std.Thread.Id,
    prepared: ?files.PreparedPumped = null,
    err: ?anyerror = null,
    fn prepare(self: *UiGate) void {
        self.prepareInner() catch |err| {
            self.err = err;
        };
    }
    fn prepareInner(self: *UiGate) !void {
        var directory = zio.tmpDir(.{});
        defer directory.cleanup();
        const file = try directory.dir.createFile(zio.io(), "private", .{ .read = true });
        defer file.close(zio.io());
        try file.writeStreamingAll(zio.io(), "bytes");
        self.prepared = try files.OwnedFileResponse.preparePumped(std.testing.allocator, self.main_thread, file, .{}, 1024);
    }
    fn cancelledPump(self: *UiGate) void {
        self.prepared.?.pump.pump() catch |err| {
            self.err = err;
            return;
        };
        self.err = error.CancellationRequired;
    }
};
test "UI thread cannot prepare or pump and rejected pumping does not consume the worker operation" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const main_thread = std.Thread.getCurrentId();
    const undefined_file: std.Io.File = undefined;
    try std.testing.expectError(error.UiThreadForbidden, files.OwnedFileResponse.preparePumped(std.testing.failing_allocator, main_thread, undefined_file, .{}, 1024));
    var state: UiGate = .{ .main_thread = main_thread };
    const worker = try std.Thread.spawn(.{}, UiGate.prepare, .{&state});
    worker.join();
    if (state.err) |err| return err;
    defer state.prepared.?.pump.deinit();
    defer state.prepared.?.response.deinit();
    try std.testing.expectError(error.UiThreadForbidden, state.prepared.?.pump.pump());
    state.prepared.?.response.deinit();
    const cleanup = try std.Thread.spawn(.{}, UiGate.cancelledPump, .{&state});
    cleanup.join();
    try std.testing.expect(state.err != null);
    try std.testing.expectEqual(error.Cancelled, state.err.?);
    state.prepared.?.pump.deinit();
    try expectCounts(0, 0);
}

extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_object_unref(*anyopaque) void;
const NeutralWorker = struct {
    owner: std.Thread.Id,
    prepared: ?stream.Prepared = null,
    err: ?anyerror = null,
    fn prepare(self: *NeutralWorker) void {
        self.prepareInner() catch |err| {
            self.err = err;
        };
    }
    fn prepareInner(self: *NeutralWorker) !void {
        var directory = zio.tmpDir(.{});
        defer directory.cleanup();
        const file = try directory.dir.createFile(zio.io(), "neutral-private", .{ .read = true });
        defer file.close(zio.io());
        try file.writeStreamingAll(zio.io(), "explicit transfer");
        try zio.posix.seekTo(file.handle, 3);
        self.prepared = try stream.PreparedSource.prepare(self.owner, file, 1024);
        try std.testing.expectEqual(@as(u64, 3), try zio.posix.position(file.handle));
    }
    fn pump(self: *NeutralWorker) void {
        self.prepared.?.pump.pump() catch |err| {
            self.err = err;
        };
    }
};
test "neutral source admission retains native stream independently of both logical owners" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const owner = std.Thread.getCurrentId();
    var state: NeutralWorker = .{ .owner = owner };
    const preparation = try std.Thread.spawn(.{}, NeutralWorker.prepare, .{&state});
    preparation.join();
    if (state.err) |err| return err;
    const prepared = &state.prepared.?;
    defer prepared.source.deinit();
    defer prepared.pump.deinit();
    try std.testing.expectEqual(@as(u64, 17), try prepared.source.authoritativeLength());
    var budget = try stream.Budget.create(owner, 1);
    defer budget.deinit();
    try budget.setLimit(2);
    try std.testing.expectError(error.InvalidFileStreamLimits, budget.setLimit(0));
    try budget.setLimit(1);
    var candidate = try prepared.source.prepareConsumer(budget, true, null);
    var borrowed = try candidate.retainControl();
    defer borrowed.deinit();
    try candidate.abort();
    try std.testing.expectError(error.CandidateMoved, candidate.abort());
    try std.testing.expectEqual(@as(u32, 0), try budget.live());
    candidate = try prepared.source.prepareConsumer(budget, true, null);
    const native_stream: *anyopaque = @ptrCast(try candidate.stream());
    _ = g_object_ref(native_stream);
    var stream_live = true;
    defer if (stream_live) g_object_unref(native_stream);
    var control = (try candidate.admit(false, true)).?;
    defer control.deinit();
    var control_copy = try control.clone();
    defer control_copy.deinit();
    try std.testing.expectError(error.CandidateMoved, candidate.stream());
    try std.testing.expectError(error.CandidateMoved, candidate.admit(false, false));
    try std.testing.expectError(error.UiThreadForbidden, prepared.pump.pump());
    const pumping = try std.Thread.spawn(.{}, NeutralWorker.pump, .{&state});
    pumping.join();
    if (state.err) |err| return err;
    budget.deinit();
    try std.testing.expectError(error.BudgetMoved, budget.live());
    var native_code: ?i32 = 91;
    try std.testing.expectError(error.BudgetMoved, prepared.source.prepareConsumer(budget, false, &native_code));
    try std.testing.expect(native_code == null);
    prepared.source.deinit();
    prepared.pump.deinit();
    try std.testing.expectEqualDeep(stream.Counts{ .physical = 1, .controls = 1, .budgets = 1 }, stream.counts());
    try std.testing.expect(control.alive());
    g_object_unref(native_stream);
    stream_live = false;
    try std.testing.expect(!control.alive() and !borrowed.alive() and !control_copy.alive());
    try std.testing.expectEqualDeep(stream.Counts{ .controls = 1 }, stream.counts());
    control.deinit();
    control_copy.cancel();
    control_copy.deinit();
    borrowed.deinit();
    try std.testing.expectEqualDeep(stream.Counts{}, stream.counts());
    try std.testing.expectError(error.ResponseMoved, prepared.source.authoritativeLength());
    try std.testing.expectError(error.PumpMoved, prepared.pump.pump());
}
