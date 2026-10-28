//! Links against the macOS SDK's AppKit with the native toolchain and finds
//! an AppKit class at run time, so CI notices when the pinned Zig cannot read
//! the runner's SDK.
const std = @import("std");

extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern "c" fn NSApplicationLoad() bool;

pub fn main() !void {
    // Referencing an AppKit symbol makes the link resolve it from the SDK.
    std.mem.doNotOptimizeAway(&NSApplicationLoad);
    if (objc_getClass("NSApplication") == null) return error.AppKitUnavailable;
    std.debug.print("AppKit linked from the SDK; NSApplication found\n", .{});
}
