//! Isolated test build only. The ordinary DA module must not be linked here.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("objbase.h");
});
extern fn zda_root_latch_create(?*anyopaque, u32, u32, *const fn (*anyopaque, u32) callconv(.c) c_int, *anyopaque, *?*anyopaque) c_int;
extern fn zda_root_latch_worker(*anyopaque) void;
extern fn zda_root_latch_owner(*anyopaque, u32) void;
extern fn zda_root_latch_finish(*anyopaque) c_int;
extern fn zda_root_latch_abort(*anyopaque) c_int;
extern fn zda_ledger_counts(*u32, *u32, *u64) void;

const Host = struct {
    app: *z.App,
    case: ?*anyopaque = null,
    tasks: [3]Task = undefined,
    completion: bool = false,
    failure: bool = false,
    const Task = struct { host: *Host, phase: u32 };

    fn post(pointer: *anyopaque, phase: u32) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(pointer));
        if (phase >= self.tasks.len) return 0;
        // Each phase is emitted once. Storage belongs to this independent
        // fixture owner and outlives the App's accepted FIFO callbacks.
        self.app.post(.{ .context = &self.tasks[phase], .call = take }) catch return 0;
        return 1;
    }
    fn take(pointer: *anyopaque) void {
        const task: *Task = @ptrCast(@alignCast(pointer));
        const self = task.host;
        if (task.phase == 2) {
            self.completion = true;
            self.app.quit();
        } else if (self.case) |case| zda_root_latch_owner(case, task.phase);
    }
    fn worker(pointer: *anyopaque) void {
        zda_root_latch_worker(pointer);
    }
};

pub fn main() !void {
    if (builtin.os.tag != .windows) return error.UnsupportedCapability;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    if (c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED) < 0) return error.ComInitializationFailed;
    defer c.CoUninitialize();
    var case_failure: ?anyerror = null;
    for (0..3) |mode| for (0..2) |close| {
        var before_accounts: u32 = 0;
        var before_blocks: u32 = 0;
        var before_bytes: u64 = 0;
        zda_ledger_counts(&before_accounts, &before_blocks, &before_bytes);
        const app = try z.App.init(gpa.allocator());
        defer app.deinit();
        const window = try app.createWindow(.{ .width = 200, .height = 100 });
        defer _ = window.destroy() catch unreachable;
        var host: Host = .{ .app = app };
        for (&host.tasks, 0..) |*task, phase| task.* = .{ .host = &host, .phase = @intCast(phase) };
        const create_line = zda_root_latch_create(window.nativeHandle(), @intCast(mode), @intCast(close), Host.post, &host, &host.case);
        if (create_line != 0) {
            std.debug.print("root point latch create C:{d}\n", .{create_line});
            return error.LatchSetupFailed;
        }
        var watchdog: Watchdog = .{ .app = app };
        watchdog.start() catch |err| {
            _ = zda_root_latch_abort(host.case.?);
            host.case = null;
            return err;
        };
        defer watchdog.stop();
        const thread = std.Thread.spawn(.{}, Host.worker, .{host.case.?}) catch |err| {
            _ = zda_root_latch_abort(host.case.?);
            host.case = null;
            return err;
        };
        // The main thread runs the real App FIFO throughout both latches. It
        // joins only after the worker's completion post or the watchdog exit.
        const run_error: ?anyerror = failed: {
            app.run() catch |err| break :failed err;
            break :failed null;
        };
        thread.join();
        const finish_line = zda_root_latch_finish(host.case.?);
        host.case = null;
        var accounts: u32 = 0;
        var blocks: u32 = 0;
        var bytes: u64 = 0;
        zda_ledger_counts(&accounts, &blocks, &bytes);
        if (run_error) |err| return err;
        try std.testing.expectEqual(before_accounts, accounts);
        try std.testing.expectEqual(before_blocks, blocks);
        try std.testing.expectEqual(before_bytes, bytes);
        try std.testing.expect(!watchdog.expired and host.completion);
        if (finish_line != 0) {
            std.debug.print("root point latch oracle C:{d}\n", .{finish_line});
            case_failure = error.RootPointFinalGateFailed;
        }
    };
    if (case_failure) |err| return err;
    std.debug.print("root point isolated latch: body/auxiliary/no-hit x owner close at actual final free; 6 cases, ledger restored\n", .{});
}
