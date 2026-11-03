const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const win = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn ziggurat_system_logind_inhibit(what: [*:0]const u8, who: [*:0]const u8, why: [*:0]const u8, timeout_ms: c_int, fd: *c_int) callconv(.c) c_int;
extern fn zsm_power_begin(display: c_int, reason: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn zsm_power_end(token: *anyopaque) callconv(.c) void;

pub const max_reason_bytes = 255;
pub const capabilities = .{ .prevent_sleep = builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos };

pub const Kind = enum {
    /// Keep the system from idle sleep; the display may still turn off.
    system,
    /// Keep the display on as well, e.g. during presentation or playback.
    display,
};
pub const Options = struct {
    kind: Kind = .system,
    /// Shown by the OS in power diagnostics (Windows `powercfg /requests`,
    /// Linux `systemd-inhibit --list`, macOS `pmset -g assertions`). UTF-8
    /// without control characters.
    reason: []const u8,
    /// Linux: who holds the inhibitor. Usually the application name.
    application: []const u8 = "",
    /// Linux: bound for the system-bus call that creates the inhibitor.
    timeout_ms: u32 = 1000,
};

/// One owned sleep assertion. Each owner holds its own native object; the OS
/// combines them, so the system may sleep again only after the last one is
/// released. Do not copy after acquire. `release` is idempotent and may run on
/// any thread; an assertion that is never released ends with the process.
///
/// Windows acquisition is a local power request; macOS begins an
/// NSProcessInfo activity that disables idle sleep. Linux performs one blocking
/// call to systemd-logind on the system bus, bounded by Options.timeout_ms;
/// call it from a worker when that latency is not acceptable on the UI thread.
pub const Assertion = struct {
    native: switch (builtin.os.tag) {
        .windows => win.HANDLE,
        .linux => c_int,
        .macos => *anyopaque,
        else => void,
    },
    kind: Kind,
    released: std.atomic.Value(bool) = .init(false),

    pub fn acquire(options: Options) !Assertion {
        try validate(options);
        switch (builtin.os.tag) {
            .windows => {
                var reason: [max_reason_bytes + 1]u16 = undefined;
                const length = std.unicode.utf8ToUtf16Le(reason[0..max_reason_bytes], options.reason) catch return error.InvalidReason;
                reason[length] = 0;
                var context = std.mem.zeroes(win.REASON_CONTEXT);
                context.Version = win.POWER_REQUEST_CONTEXT_VERSION;
                context.Flags = win.POWER_REQUEST_CONTEXT_SIMPLE_STRING;
                context.Reason.SimpleReasonString = &reason;
                const handle = win.PowerCreateRequest(&context);
                if (handle == win.INVALID_HANDLE_VALUE or handle == null) return error.PowerRequestFailed;
                errdefer _ = win.CloseHandle(handle);
                if (win.PowerSetRequest(handle, win.PowerRequestSystemRequired) == 0) return error.PowerRequestFailed;
                if (options.kind == .display and win.PowerSetRequest(handle, win.PowerRequestDisplayRequired) == 0) {
                    _ = win.PowerClearRequest(handle, win.PowerRequestSystemRequired);
                    return error.PowerRequestFailed;
                }
                return .{ .native = handle, .kind = options.kind };
            },
            .linux => {
                var why: [max_reason_bytes + 1]u8 = undefined;
                var who: [max_reason_bytes + 1]u8 = undefined;
                var fd: c_int = -1;
                const what: [*:0]const u8 = if (options.kind == .display) "sleep:idle" else "sleep";
                const status = ziggurat_system_logind_inhibit(what, terminated(&who, if (options.application.len == 0) "application" else options.application), terminated(&why, options.reason), @intCast(options.timeout_ms), &fd);
                return switch (status) {
                    0 => .{ .native = fd, .kind = options.kind },
                    1 => error.ServiceUnavailable,
                    2 => error.AccessDenied,
                    3 => error.Timeout,
                    else => error.PowerRequestFailed,
                };
            },
            .macos => {
                var why: [max_reason_bytes + 1]u8 = undefined;
                const token = zsm_power_begin(@intFromBool(options.kind == .display), terminated(&why, options.reason)) orelse return error.PowerRequestFailed;
                return .{ .native = token, .kind = options.kind };
            },
            else => return error.UnsupportedCapability,
        }
    }
    pub fn release(self: *Assertion) void {
        if (self.released.swap(true, .acq_rel)) return;
        switch (builtin.os.tag) {
            .windows => {
                if (self.kind == .display) _ = win.PowerClearRequest(self.native, win.PowerRequestDisplayRequired);
                _ = win.PowerClearRequest(self.native, win.PowerRequestSystemRequired);
                _ = win.CloseHandle(self.native);
            },
            // logind drops the inhibitor when the last descriptor closes.
            .linux => zio.posix.close(self.native),
            .macos => zsm_power_end(self.native),
            else => {},
        }
    }
};

fn validate(options: Options) !void {
    for ([_][]const u8{ options.reason, options.application }, 0..) |text, index| {
        if ((index == 0 and text.len == 0) or text.len > max_reason_bytes or !std.unicode.utf8ValidateSlice(text)) return error.InvalidReason;
        for (text) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidReason;
    }
    if (options.timeout_ms == 0 or options.timeout_ms > 60_000) return error.InvalidTimeout;
}
fn terminated(storage: *[max_reason_bytes + 1]u8, text: []const u8) [*:0]const u8 {
    @memcpy(storage[0..text.len], text);
    storage[text.len] = 0;
    return storage[0..text.len :0];
}

test "power assertion input is validated before the OS is called" {
    try std.testing.expectError(error.InvalidReason, Assertion.acquire(.{ .reason = "" }));
    try std.testing.expectError(error.InvalidReason, Assertion.acquire(.{ .reason = "line\nbreak" }));
    try std.testing.expectError(error.InvalidReason, Assertion.acquire(.{ .reason = "ok", .application = "\xff" }));
    try std.testing.expectError(error.InvalidReason, Assertion.acquire(.{ .reason = &@as([256]u8, @splat('x')) }));
    try std.testing.expectError(error.InvalidTimeout, Assertion.acquire(.{ .reason = "ok", .timeout_ms = 0 }));
}
