const std = @import("std");
pub fn main() void {
    std.debug.print("native_header_value={d}\n", .{@import("fixture_helper").value()});
}
