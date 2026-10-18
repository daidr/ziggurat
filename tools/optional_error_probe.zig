// Standalone pinned-toolchain reproducer; intentionally excluded from normal tests.
const std = @import("std");
const diagnostics = @import("diagnostics");
const State = struct { prefix: [160]u8 = @splat(0), expected: ?anyerror, count: usize = 0, failed: bool = false };
noinline fn report(ptr: *anyopaque, value: diagnostics.Diagnostic) void {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (value.err == state.expected and value.err != null) state.count += 1 else {
        std.debug.print("comparison rejected actual={any}, expected={any}\n", .{ value.err, state.expected });
        state.failed = true;
    }
}
noinline fn poison() void {
    var bytes: [512]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i);
    std.mem.doNotOptimizeAway(&bytes);
}
pub fn main() !void {
    var state: State = .{ .expected = error.Example };
    for (0..10) |_| {
        poison();
        const sink: diagnostics.Sink = .{ .context = &state, .emit = report };
        sink.report(.{ .domain = .renderer, .operation = .paint, .err = error.Example });
        if (state.failed) {
            return error.CompilerComparisonFailure;
        }
    }
    std.debug.print("optional error comparison matched payloads\n", .{});
}
