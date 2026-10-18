const std = @import("std");
const native = @import("ziggurat_native_stream");
const files = @import("ziggurat_file_stream");
extern fn zwk_native_stream_test_run() c_int;
extern fn zwk_stream_test_read(*anyopaque, u64) c_int;
extern fn zwk_stream_test_ref(*anyopaque) *anyopaque;
extern fn zwk_stream_test_unref(*anyopaque) void;

test "native generated channel has one physical ledger and monotonic terminals" {
    defer {
        const counts = files.counts();
        std.debug.print("native group final refs: {any}\n", .{counts});
        std.testing.expectEqualDeep(files.Counts{}, counts) catch @panic("Native group references remain");
    }
    try std.testing.expectEqual(@as(c_int, 0), zwk_native_stream_test_run());
}
test "public producer Source and Writer drive the native consumer" {
    std.debug.print("native stream public layout: Source={d} Writer={d} Prepared={d}\n", .{ @sizeOf(native.Source), @sizeOf(native.Writer), @sizeOf(native.Prepared) });
    defer std.testing.expectEqualDeep(files.Counts{}, files.counts()) catch @panic("Public producer references remain");
    const State = struct {
        owner: std.Thread.Id,
        pair: ?native.Prepared = null,
        failure: ?anyerror = null,
        fn prepare(self: *@This()) void {
            self.pair = native.prepare(self.owner, 251 * 3, 1024) catch |err| {
                self.failure = err;
                return;
            };
        }
        fn produce(self: *@This()) void {
            var writer = self.pair.?.writer.take() catch unreachable;
            defer writer.deinit();
            self.write(&writer) catch |err| {
                self.failure = err;
            };
        }
        fn write(_: *@This(), writer: *native.Writer) !void {
            try std.testing.expectEqual(native.Disposition.body, try writer.waitAccepted());
            var bytes: [251 * 3]u8 = undefined;
            for (&bytes, 0..) |*byte, i| byte.* = @intCast(i % 251);
            try writer.writeAll(&bytes);
            try writer.finish();
            try std.testing.expectError(error.Finished, writer.finish());
        }
    };
    var state: State = .{ .owner = std.Thread.getCurrentId() };
    (try std.Thread.spawn(.{}, State.prepare, .{&state})).join();
    if (state.failure) |err| return err;
    defer state.pair.?.source.deinit();
    defer state.pair.?.writer.deinit();
    var budget = try files.Budget.create(state.owner, 1);
    defer budget.deinit();
    var candidate = try state.pair.?.source.prepareConsumer(budget, false, null);
    const stream = zwk_stream_test_ref(@ptrCast(try candidate.stream()));
    defer zwk_stream_test_unref(stream);
    var control = (try candidate.admit(false, true)).?;
    defer control.deinit();
    const producer = try std.Thread.spawn(.{}, State.produce, .{&state});
    const read = zwk_stream_test_read(stream, 251 * 3);
    if (read == 0) control.cancel();
    producer.join();
    if (state.failure) |err| return err;
    try std.testing.expectEqual(@as(c_int, 1), read);
}
