const std = @import("std");

/// Physical immutable memory responses, including EOF/closed streams retained
/// by the engine. The same attached View budget survives reload and recovery.
pub const Limits = struct {
    max_live_responses: u8 = 8,
    max_live_bytes: usize = 32 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.max_live_responses == 0 or self.max_live_responses > 8 or self.max_live_bytes == 0 or self.max_live_bytes > 32 * 1024 * 1024)
            return error.InvalidCustomLocalLimits;
    }
};
pub const ResourceCounts = struct { budgets: u32, streams: u32, body_bytes: u32 };

test "custom local physical limits remain explicit and bounded" {
    try (Limits{}).validate();
    try std.testing.expectError(error.InvalidCustomLocalLimits, (Limits{ .max_live_responses = 0 }).validate());
    try std.testing.expectError(error.InvalidCustomLocalLimits, (Limits{ .max_live_responses = 9 }).validate());
    try std.testing.expectError(error.InvalidCustomLocalLimits, (Limits{ .max_live_bytes = 0 }).validate());
    try std.testing.expectError(error.InvalidCustomLocalLimits, (Limits{ .max_live_bytes = 32 * 1024 * 1024 + 1 }).validate());
}
