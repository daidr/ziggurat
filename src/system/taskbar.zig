const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const identity = @import("identity.zig");
extern fn ziggurat_system_taskbar_create(taskbar: *?*anyopaque, apartment: *c_int) callconv(.c) i32;
extern fn ziggurat_system_taskbar_progress(taskbar: *anyopaque, window: *anyopaque, state: c_int, completed: u64, total: u64) callconv(.c) i32;
extern fn ziggurat_system_taskbar_overlay(taskbar: *anyopaque, window: *anyopaque, icon: ?*anyopaque, description: [*:0]const u16) callconv(.c) i32;
extern fn ziggurat_system_taskbar_release(taskbar: *anyopaque, apartment: c_int) callconv(.c) void;
extern fn ziggurat_system_launcher_open(status: *c_int) callconv(.c) ?*anyopaque;
extern fn ziggurat_system_launcher_update(connection: *anyopaque, uri: [*:0]const u8, path: [*:0]const u8, progress_visible: c_int, progress: f64, count_visible: c_int, count: i64, urgent: c_int) callconv(.c) c_int;
extern fn ziggurat_system_launcher_close(connection: *anyopaque) callconv(.c) void;

pub const capabilities = .{
    // Windows taskbar button progress; Linux launcher entry progress read by
    // docks and task managers that implement the launcher entry protocol.
    .progress = builtin.os.tag == .windows or builtin.os.tag == .linux,
    // Windows taskbar overlay icon.
    .overlay_icon = builtin.os.tag == .windows,
    // Linux launcher entry count. Windows offers numeric badges only to
    // packaged applications, so it is not reported here.
    .badge_count = builtin.os.tag == .linux,
    .attention = builtin.os.tag == .linux,
};

pub const Progress = union(enum) {
    none,
    indeterminate,
    /// Fractions in 0...1.
    normal: f32,
    paused: f32,
    failed: f32,
};

/// Taskbar or dock state for one application. Create, use and deinit it on
/// the App's owner thread. Do not copy after init.
///
/// Windows: one ITaskbarList3 COM object; progress and overlays are per
/// window and the shell drops them when the window is destroyed. The shell
/// accepts them only once the taskbar button exists, so call after the
/// window is shown. Linux: one session-bus connection; every change emits a
/// launcher entry Update signal for `<id>.desktop`, which applies to the whole
/// application. Docks that start later see the next change, not the last one.
pub const Taskbar = struct {
    thread: std.Thread.Id,
    native: ?*anyopaque,
    apartment: c_int = 0,
    id_storage: [identity.max_id_bytes]u8 = undefined,
    id_len: usize = 0,
    linux_state: struct { progress: ?f64 = null, count: ?i64 = null, urgent: bool = false } = .{},

    /// Linux connects to the session bus synchronously here; do it once at
    /// startup, not per change.
    pub fn init(id: []const u8) !Taskbar {
        try identity.validate(id);
        var self: Taskbar = .{ .thread = std.Thread.getCurrentId(), .native = null };
        @memcpy(self.id_storage[0..id.len], id);
        self.id_len = id.len;
        switch (builtin.os.tag) {
            .windows => if (ziggurat_system_taskbar_create(&self.native, &self.apartment) < 0) return error.TaskbarUnavailable,
            .linux => {
                var status: c_int = 0;
                self.native = ziggurat_system_launcher_open(&status) orelse return error.ServiceUnavailable;
            },
            else => return error.UnsupportedCapability,
        }
        return self;
    }
    pub fn deinit(self: *Taskbar) void {
        std.debug.assert(self.thread == std.Thread.getCurrentId());
        const native = self.native orelse return;
        switch (builtin.os.tag) {
            .windows => ziggurat_system_taskbar_release(native, self.apartment),
            .linux => ziggurat_system_launcher_close(native),
            else => {},
        }
        self.native = null;
    }
    fn require(self: *Taskbar, window: z.Window) !*anyopaque {
        window.app.assertOwner();
        if (self.thread != std.Thread.getCurrentId()) return error.WrongThread;
        return self.native orelse error.Closed;
    }
    pub fn setProgress(self: *Taskbar, window: z.Window, progress: Progress) !void {
        const native = try self.require(window);
        const fraction: ?f32 = switch (progress) {
            .none, .indeterminate => null,
            inline else => |value| value,
        };
        if (fraction) |value| if (!(value >= 0 and value <= 1)) return error.InvalidProgress;
        switch (builtin.os.tag) {
            .windows => {
                const hwnd = window.nativeHandle() orelse return error.Closed;
                // TBPF_NOPROGRESS, INDETERMINATE, NORMAL, ERROR, PAUSED.
                const state: c_int = switch (progress) {
                    .none => 0,
                    .indeterminate => 1,
                    .normal => 2,
                    .failed => 4,
                    .paused => 8,
                };
                const scale: u64 = 10_000;
                const completed: u64 = if (fraction) |value| @intFromFloat(@round(value * scale)) else 0;
                if (ziggurat_system_taskbar_progress(native, hwnd, state, completed, scale) < 0) return error.TaskbarUnavailable;
            },
            .linux => {
                const previous = self.linux_state;
                // The launcher entry protocol has no indeterminate or error state.
                self.linux_state.progress = switch (progress) {
                    .none => null,
                    .indeterminate => 0,
                    inline else => |value| value,
                };
                self.emit(native) catch |err| {
                    self.linux_state = previous;
                    return err;
                };
            },
            else => return error.UnsupportedCapability,
        }
    }
    /// Windows: borrowed HICON copied by the shell, or null to clear. The
    /// description is the accessible text for the overlay.
    pub fn setOverlay(self: *Taskbar, window: z.Window, icon: ?*anyopaque, description: []const u8) !void {
        const native = try self.require(window);
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        if (description.len > 255) return error.InvalidText;
        var text: [256]u16 = undefined;
        const length = std.unicode.utf8ToUtf16Le(&text, description) catch return error.InvalidText;
        text[length] = 0;
        const hwnd = window.nativeHandle() orelse return error.Closed;
        if (ziggurat_system_taskbar_overlay(native, hwnd, icon, text[0..length :0]) < 0) return error.TaskbarUnavailable;
    }
    /// Linux: launcher entry count; null hides it.
    pub fn setBadgeCount(self: *Taskbar, window: z.Window, count: ?u32) !void {
        const native = try self.require(window);
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        const previous = self.linux_state;
        self.linux_state.count = if (count) |value| value else null;
        self.emit(native) catch |err| {
            self.linux_state = previous;
            return err;
        };
    }
    /// Linux: ask the dock to draw attention to the application.
    pub fn setAttention(self: *Taskbar, window: z.Window, urgent: bool) !void {
        const native = try self.require(window);
        if (builtin.os.tag != .linux) return error.UnsupportedCapability;
        const previous = self.linux_state;
        self.linux_state.urgent = urgent;
        self.emit(native) catch |err| {
            self.linux_state = previous;
            return err;
        };
    }
    fn emit(self: *Taskbar, native: *anyopaque) !void {
        var uri: [identity.max_id_bytes + 32]u8 = undefined;
        var path: [identity.max_id_bytes * 2 + 48]u8 = undefined;
        const id = self.id_storage[0..self.id_len];
        const uri_z = try std.fmt.bufPrintSentinel(&uri, "application://{s}.desktop", .{id}, 0);
        // Object paths allow [A-Za-z0-9_]; encode the identity as hex.
        var hex: [identity.max_id_bytes * 2]u8 = undefined;
        for (id, 0..) |byte, index| _ = std.fmt.bufPrint(hex[index * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
        const path_z = try std.fmt.bufPrintSentinel(&path, "/com/canonical/unity/launcherentry/{s}", .{hex[0 .. id.len * 2]}, 0);
        const state = self.linux_state;
        if (ziggurat_system_launcher_update(native, uri_z, path_z, @intFromBool(state.progress != null), state.progress orelse 0, @intFromBool(state.count != null), state.count orelse 0, @intFromBool(state.urgent)) != 0) return error.SignalFailed;
    }
};
