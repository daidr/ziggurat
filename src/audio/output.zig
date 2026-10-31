const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

/// The output's format: every player is resampled to it.
pub const sample_rate = 48000;
pub const channels = 2;
/// Frames mixed and written at a time: 10 ms.
pub const period_frames = sample_rate / 100;

/// Why the output is not the system's audio output.
pub const OpenError = error{
    /// No audio output on this platform.
    Unsupported,
    /// The system has no output device.
    NoDevice,
    /// The audio system or library is missing or refused the connection.
    BackendUnavailable,
    /// The device exists but could not be opened for this format.
    DeviceFailed,
    OutOfMemory,
};

/// A device's write failing closes it; the engine opens one again.
pub const WriteError = error{
    DeviceLost,
    /// The system's default output changed: play on the new one.
    DefaultChanged,
    /// The device stopped asking for frames.
    Unresponsive,
    /// A silent stand-in asking for the real device to be tried again.
    Retry,
};

/// Text for an open failure, such as the audio system's own message.
pub const Detail = struct {
    buffer: [192]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Detail, comptime fmt: []const u8, args: anytype) void {
        self.len = (std.fmt.bufPrint(&self.buffer, fmt, args) catch @as([]const u8, self.buffer[0..])).len;
    }

    pub fn append(self: *Detail, comptime fmt: []const u8, args: anytype) void {
        const rest = self.buffer[self.len..];
        self.len += (std.fmt.bufPrint(rest, fmt, args) catch rest).len;
    }

    pub fn slice(self: *const Detail) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// An open audio output taking interleaved stereo `f32` frames at
/// `sample_rate`. Every call runs on the engine's output thread.
pub const Device = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Plays `samples` after those written before, waiting while the
        /// device holds enough already.
        write: *const fn (context: *anyopaque, samples: []const f32) WriteError!void,
        close: *const fn (context: *anyopaque) void,
    };

    pub fn write(self: Device, samples: []const f32) WriteError!void {
        return self.vtable.write(self.context, samples);
    }

    pub fn close(self: Device) void {
        self.vtable.close(self.context);
    }
};

/// Opens a device on the engine's output thread, as a test backend or an
/// app's own output does. The context outlives the engine.
pub const Opener = struct {
    context: *anyopaque,
    open: *const fn (context: *anyopaque, detail: *Detail) OpenError!Device,
};

/// The time a null device keeps, which tests replace.
pub const Clock = struct {
    context: ?*anyopaque = null,
    now: *const fn (?*anyopaque) i128 = systemNow,
    sleep: *const fn (?*anyopaque, u64) void = systemSleep,

    fn systemNow(_: ?*anyopaque) i128 {
        return zio.nanoTimestamp();
    }

    fn systemSleep(_: ?*anyopaque, nanoseconds: u64) void {
        zio.sleep(nanoseconds);
    }
};

/// Plays nothing, on time: players still end when they would have. One
/// standing in for a device that failed to open fails after a while, so
/// that the engine tries the device again.
pub const NullDevice = struct {
    clock: Clock,
    next: i128,
    retry: ?i128,

    pub const retry_after = 2 * std.time.ns_per_s;

    pub fn init(clock: Clock, retry: bool) NullDevice {
        const now = clock.now(clock.context);
        return .{ .clock = clock, .next = now, .retry = if (retry) now + retry_after else null };
    }

    pub fn device(self: *NullDevice) Device {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: Device.VTable = .{ .write = writeFn, .close = closeFn };

    fn writeFn(context: *anyopaque, samples: []const f32) WriteError!void {
        const self: *NullDevice = @ptrCast(@alignCast(context));
        const now = self.clock.now(self.clock.context);
        if (self.retry) |retry| if (now > retry) return error.Retry;
        // Behind, as after a sleep: don't hurry to catch up.
        if (now - self.next > 100 * std.time.ns_per_ms) self.next = now;
        self.next += @divFloor(@as(i128, samples.len / channels) * std.time.ns_per_s, sample_rate);
        const wait = self.next - self.clock.now(self.clock.context);
        if (wait > 0) self.clock.sleep(self.clock.context, @intCast(zio.asUnsigned(wait)));
    }

    fn closeFn(_: *anyopaque) void {}
};

pub const system = switch (builtin.os.tag) {
    .windows => @import("windows.zig"),
    .linux => @import("linux.zig"),
    else => struct {
        pub const Storage = struct {};
        pub fn threadInit() void {}
        pub fn threadDeinit() void {}
        pub fn open(_: *Storage, detail: *Detail) OpenError!Device {
            detail.set("no audio output on this platform", .{});
            return error.Unsupported;
        }
    },
};

test "a null device keeps time, does not hurry once behind, and asks for a retry" {
    const Fake = struct {
        clock: i128 = 1_000_000_000,
        fn now(context: ?*anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.clock;
        }
        fn sleep(context: ?*anyopaque, nanoseconds: u64) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.clock += nanoseconds;
        }
    };
    var fake = Fake{};
    const start = fake.clock;
    var null_device = NullDevice.init(.{ .context = &fake, .now = Fake.now, .sleep = Fake.sleep }, true);
    const output = null_device.device();
    const chunk = @as([period_frames * channels]f32, @splat(0));
    for (0..10) |_| try output.write(&chunk);
    try std.testing.expectEqual(@as(i128, 100 * std.time.ns_per_ms), fake.clock - start);
    // Late by a second, as after the computer slept: the next chunk takes
    // its 10 ms from now.
    fake.clock += std.time.ns_per_s;
    const late = fake.clock;
    try output.write(&chunk);
    try std.testing.expectEqual(@as(i128, 10 * std.time.ns_per_ms), fake.clock - late);
    fake.clock = start + 2 * std.time.ns_per_s + std.time.ns_per_ms;
    try std.testing.expectError(error.Retry, output.write(&chunk));
}
