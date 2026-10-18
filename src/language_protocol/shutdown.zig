//! Bounded control storage; no process, thread, clock or application owner.
const std = @import("std");
const codec = @import("codec.zig");

pub const Limits = struct {
    body_bytes: usize = 16 * 1024,
    json_bytes: usize = 128 * 1024,
    tokens: usize = 1024,
    depth: usize = 16,
    /// Cumulative conservative byte visits across retries, not elapsed CPU time.
    work_bytes: usize = 256 * 1024,

    pub fn validate(self: Limits) !void {
        if (self.body_bytes < 64 or self.body_bytes > 64 * 1024 or self.json_bytes > 4 * 1024 * 1024 or self.tokens > 8192 or self.depth > 32 or self.work_bytes == 0 or self.work_bytes > 16 * 1024 * 1024) return error.InvalidLimits;
        try self.framing().validate();
    }
    pub fn framing(self: Limits) codec.Limits {
        return .{ .header_bytes = 64, .body_bytes = self.body_bytes, .json_bytes = self.json_bytes, .tokens = self.tokens, .depth = self.depth };
    }
    pub fn encoding(self: Limits) codec.Limits {
        var result = self.framing();
        result.body_bytes = @min(result.body_bytes, 128);
        return result;
    }
};

pub const Options = struct {
    /// Absolute time in the host's monotonic nanosecond domain. No clock is read.
    deadline_ns: u64,
    limits: Limits = .{},
};
pub const Stage = enum(u4) {
    idle,
    captured,
    preparing,
    prepared,
    sent,
    receiving,
    reply_pending,
    replied,
    preparing_exit,
    exit_prepared,
    exit_accepted,
    closing,
    reply_finishing,
    failed,
    sending,
};
pub const max_serial = std.math.maxInt(u64) >> 4;
pub fn stamp(serial: u64, stage: Stage) u64 {
    std.debug.assert(serial <= max_serial);
    return (serial << 4) | @intFromEnum(stage);
}
pub fn stageOf(word: u64) Stage {
    return @enumFromInt(@as(u4, @truncate(word)));
}

pub const Control = struct {
    serial: u64 = 0,
    word: std.atomic.Value(u64) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),
    reservation_bytes: usize = 0,

    pub fn active(self: *const Control) bool {
        return stageOf(self.word.load(.acquire)) != .idle;
    }
    pub fn check(self: *const Control, serial: u64) !Stage {
        const word = self.word.load(.acquire);
        if (word >> 4 != serial or serial == 0) return error.StaleShutdown;
        const stage = stageOf(word);
        if (stage == .idle) return error.WorkClosed;
        return stage;
    }
    pub fn claim(self: *Control, serial: u64, from: Stage, to: Stage) !void {
        if (self.word.cmpxchgStrong(stamp(serial, from), stamp(serial, to), .acq_rel, .acquire)) |word| {
            if (word >> 4 != serial) return error.StaleShutdown;
            return switch (stageOf(word)) {
                .preparing, .receiving, .preparing_exit, .closing, .reply_finishing, .sending => error.Busy,
                .idle => error.WorkClosed,
                else => error.InvalidPhase,
            };
        }
    }
    pub fn publish(self: *Control, serial: u64, stage: Stage) void {
        std.debug.assert(self.word.load(.monotonic) >> 4 == serial);
        self.word.store(stamp(serial, stage), .release);
    }
};

test "shutdown control CAS contains generation and never claims a replacement" {
    var control: Control = .{};
    control.serial = 1;
    control.word.store(stamp(1, .captured), .release);
    try control.claim(1, .captured, .preparing);
    try std.testing.expectError(error.Busy, control.claim(1, .captured, .preparing));
    control.publish(1, .idle);
    control.serial = 2;
    control.word.store(stamp(2, .captured), .release);
    try std.testing.expectError(error.StaleShutdown, control.claim(1, .captured, .preparing));
    try std.testing.expectEqual(Stage.captured, try control.check(2));
}
