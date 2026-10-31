const std = @import("std");
const builtin = @import("builtin");

/// A panic handler for macOS smokes that prints the message, the image base
/// and the frame-pointer chain, then aborts. The default handler's stack
/// symbolization can stall on CI; scripts/macos-symbolize.sh turns these
/// lines into source locations with atos.
pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (builtin.os.tag != .macos) std.debug.defaultPanic(msg, first_trace_addr);
    const base = @intFromPtr(std.c._dyld_get_image_header(0));
    std.debug.print("ziggurat-panic: {s}\nziggurat-panic-base: 0x{x}\n", .{ msg, base });
    if (first_trace_addr) |address| std.debug.print("ziggurat-panic-frame: 0x{x}\n", .{address});
    var fp = @frameAddress();
    var depth: usize = 0;
    while (fp != 0 and fp % @alignOf(usize) == 0 and depth < 32) : (depth += 1) {
        const frame: *const [2]usize = @ptrFromInt(fp);
        if (frame[1] == 0) break;
        std.debug.print("ziggurat-panic-frame: 0x{x}\n", .{frame[1]});
        if (frame[0] <= fp) break;
        fp = frame[0];
    }
    std.c.abort();
}

/// DebugAllocator configuration for smokes. On macOS a free inside an
/// engine callback makes the allocator walk the stack through system
/// frameworks, whose unwind entries the Zig 0.17 unwinder misreads as a
/// corrupt value; the macOS smokes record no allocation stack traces.
pub const allocator_config: std.heap.DebugAllocatorConfig = if (builtin.os.tag == .macos) .{ .stack_trace_frames = 0 } else .{};
