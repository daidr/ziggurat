// Isolated explicit test root. Link exactly one fault-enabled HTTP/file pair;
// ordinary consumers neither import this root nor reference its test hooks.
pub const file_response_faults = true;
pub fn main() !void {
    return @import("https_resources_smoke.zig").main();
}
