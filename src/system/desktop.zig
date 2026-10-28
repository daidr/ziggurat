//! Desktop environment snapshots and change subscriptions. Every call runs on
//! the App owner thread. Snapshots write caller storage and allocate nothing;
//! a Watch owns one native subscription from start until stop or App shutdown.
//! There is no polling timer: changes come from native notifications only.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");

const os = builtin.os.tag;
const enabled = !builtin.is_test and (os == .windows or os == .linux);
const windows = if (enabled and os == .windows) @import("desktop_windows.zig") else struct {
    pub const Native = struct {};
};

pub const capabilities = .{
    .monitors = os == .windows or os == .linux,
    .monitor_refresh_rate = os == .windows or os == .linux,
    .preferences = os == .windows or os == .linux,
    // Linux GtkSettings exposes no accent color; Preferences.accent is null.
    .accent_color = os == .windows,
    // Linux reports null: GtkSettings has no transparency preference.
    .reduce_transparency = os == .windows,
    // Windows GetSystemPowerStatus; Linux bounded /sys/class/power_supply read.
    .power_source = os == .windows or os == .linux,
    // Windows SystemStatusFlag; Linux GPowerProfileMonitor when present at runtime.
    .power_saver = os == .windows or os == .linux,
    // Windows requires GetNetworkConnectivityHint at runtime (unknown otherwise).
    .network = os == .windows or os == .linux,
    .watch_monitors = os == .windows or os == .linux,
    .watch_preferences = os == .windows or os == .linux,
    // Linux watches only the power-saver flag, not AC/battery or percentage.
    .watch_power_source = os == .windows,
    .watch_power_saver = os == .windows or os == .linux,
    .watch_network = os == .windows or os == .linux,
    .beep = os == .windows or os == .linux,
    // Linux X11 only; Wayland keeps the global pointer position private.
    .cursor_position = os == .windows or os == .linux,
};

/// Native desktop coordinates, the same convention as core `ScreenPoint`:
/// physical pixels on Windows, GDK logical coordinates on X11.
pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };
pub const Monitor = struct {
    bounds: Rect,
    work_area: Rect,
    /// Windows effective DPI / 96; GDK integer monitor scale factor on Linux.
    scale: f32,
    primary: bool,
    /// Current mode refresh rate rounded to Hz, null when the system reports none.
    refresh_hz: ?u32,
};
/// A destination of this length always suffices. More native monitors fail
/// with TooManyMonitors instead of a truncated snapshot.
pub const max_monitors = 32;

pub const ColorScheme = enum { light, dark, unknown };
pub const Preferences = struct {
    color_scheme: ColorScheme = .unknown,
    /// 0xRRGGBB, null when the platform has no accent color.
    accent: ?u32 = null,
    high_contrast: bool = false,
    reduce_motion: bool = false,
    /// null when the platform exposes no transparency preference.
    reduce_transparency: ?bool = null,
    /// Text scaling relative to the platform default of 1.0.
    text_scale: f32 = 1,
};
pub const PowerSource = enum { ac, battery, unknown };
pub const Power = struct { source: PowerSource = .unknown, battery_percent: ?u8 = null, saver: ?bool = null };
/// `online` only describes local network connectivity. No server is probed.
pub const NetworkState = enum { online, offline, unknown };
pub const Network = struct { state: NetworkState = .unknown, metered: ?bool = null };

/// Selected kinds for Watch.start and the set delivered to on_change.
pub const Kinds = struct {
    monitors: bool = false,
    preferences: bool = false,
    power: bool = false,
    network: bool = false,

    pub fn bits(self: Kinds) u32 {
        return @as(u32, @intFromBool(self.monitors)) | @as(u32, @intFromBool(self.preferences)) << 1 |
            @as(u32, @intFromBool(self.power)) << 2 | @as(u32, @intFromBool(self.network)) << 3;
    }
    pub fn fromBits(value: u32) Kinds {
        return .{ .monitors = value & 1 != 0, .preferences = value & 2 != 0, .power = value & 4 != 0, .network = value & 8 != 0 };
    }
};
/// Kinds that changed since the previous notification. The host re-queries.
pub const Change = Kinds;

/// Writes all monitors to destination and returns their count. A destination
/// shorter than the native count returns CapacityExceeded without writing.
pub fn monitors(app: *z.App, destination: []Monitor) !usize {
    app.assertOwner();
    if (comptime !enabled) return error.UnsupportedCapability;
    var staging: [max_monitors]Monitor = undefined;
    const count = if (os == .windows) try windows.monitors(&staging) else try linuxMonitors(&staging);
    if (count > destination.len) return error.CapacityExceeded;
    @memcpy(destination[0..count], staging[0..count]);
    return count;
}

pub fn preferences(app: *z.App) !Preferences {
    app.assertOwner();
    if (comptime !enabled) return error.UnsupportedCapability;
    if (os == .windows) return windows.preferences();
    var native: NativePreferences = undefined;
    try check(zsd_preferences(&native));
    return .{
        .color_scheme = switch (native.scheme) {
            1 => .light,
            2 => .dark,
            else => .unknown,
        },
        .high_contrast = native.high_contrast != 0,
        .reduce_motion = native.reduce_motion != 0,
        .text_scale = native.text_scale,
    };
}

pub fn power(app: *z.App) !Power {
    app.assertOwner();
    if (comptime !enabled) return error.UnsupportedCapability;
    if (os == .windows) return windows.power();
    var native: NativePower = undefined;
    try check(zsd_power(&native));
    return .{
        .source = switch (native.source) {
            1 => .ac,
            2 => .battery,
            else => .unknown,
        },
        .battery_percent = if (native.percent >= 0 and native.percent <= 100) @intCast(native.percent) else null,
        .saver = if (native.saver < 0) null else native.saver != 0,
    };
}

pub fn network(app: *z.App) !Network {
    app.assertOwner();
    if (comptime !enabled) return error.UnsupportedCapability;
    if (os == .windows) return windows.network();
    var native: NativeNetwork = undefined;
    try check(zsd_network(&native));
    return .{
        .state = switch (native.state) {
            1 => .online,
            2 => .offline,
            else => .unknown,
        },
        .metered = if (native.metered < 0) null else native.metered != 0,
    };
}

/// Plays the system alert sound.
pub fn beep(app: *z.App) !void {
    app.assertOwner();
    if (comptime !enabled) return error.UnsupportedCapability;
    if (os == .windows) return windows.beep();
    try check(zsd_beep());
}

/// The pointer position in native desktop coordinates, those of `Monitor`.
pub fn cursorPosition(app: *z.App) !z.ScreenPoint {
    app.assertOwner();
    if (comptime !enabled) return error.UnsupportedCapability;
    if (os == .windows) return windows.cursorPosition();
    var point: z.ScreenPoint = .{ .x = 0, .y = 0 };
    try check(zsd_cursor(&point.x, &point.y));
    return point;
}

/// Live native watch states owned by this module: Windows hidden windows and
/// Linux refcounted GObject subscriptions. Owner thread only.
pub fn resourceCount() usize {
    if (comptime !enabled) return 0;
    if (os == .windows) return windows.resourceCount();
    return zsd_resource_count();
}

/// Caller-owned change subscription. After start the Watch must not move and
/// its context must stay valid until stop returns or App shutdown stops it.
/// A stop requested while the App is already stopping keeps the storage
/// borrowed until App shutdown completes. on_change runs on the owner thread
/// with at most one notification per kind per native burst; it may stop or
/// free the Watch, and no callback reaches a stopped Watch.
pub const Watch = struct {
    context: *anyopaque,
    on_change: *const fn (*anyopaque, Change) void,
    app: ?*z.App = null,
    kinds: Kinds = .{},
    stop_node: z.StopParticipant,
    token: ?z.StopToken = null,
    native: Native = .{},

    const Native = if (enabled and os == .windows) windows.Native else struct { handle: ?*anyopaque = null };

    pub fn init(context: *anyopaque, on_change: *const fn (*anyopaque, Change) void) Watch {
        return .{ .context = context, .on_change = on_change, .stop_node = .{ .context = context, .stop = stopFromApp } };
    }

    /// Begins this Watch's own native subscription and registers it with the
    /// App stop protocol. Failure leaves the Watch stopped and unregistered.
    pub fn start(self: *Watch, app: *z.App, kinds: Kinds) !void {
        app.assertOwner();
        if (self.app != null) return error.AlreadyStarted;
        if (kinds.bits() == 0) return error.EmptySelection;
        if (comptime !enabled) return error.UnsupportedCapability;
        self.stop_node = .{ .context = self, .stop = stopFromApp };
        const token = try app.registerStop(&self.stop_node);
        self.kinds = kinds;
        self.app = app;
        self.token = token;
        errdefer {
            _ = app.cancelStop(token) catch false;
            self.app = null;
            self.token = null;
        }
        if (os == .windows) {
            try windows.start(self);
        } else {
            var handle: ?*anyopaque = null;
            try check(zsd_watch_start(kinds.bits(), self, nativeChanged, &handle));
            self.native.handle = handle;
        }
    }

    /// Revokes the native subscription. Idempotent; safe inside on_change.
    pub fn stop(self: *Watch) void {
        const app = self.app orelse return;
        app.assertOwner();
        if (self.token) |token| {
            // StopInProgress: the App stop batch already took this node and
            // will call stopFromApp later, which then finds nothing to do.
            _ = app.cancelStop(token) catch false;
        }
        self.revoke();
    }

    pub fn running(self: *const Watch) bool {
        return self.app != null;
    }

    fn revoke(self: *Watch) void {
        if (comptime enabled) {
            if (os == .windows) {
                windows.stop(self);
            } else if (self.native.handle) |handle| {
                self.native.handle = null;
                zsd_watch_stop(handle);
            }
        }
        self.app = null;
        self.token = null;
    }

    fn stopFromApp(ptr: *anyopaque) anyerror!void {
        const self: *Watch = @ptrCast(@alignCast(ptr));
        self.token = null;
        if (self.app != null) self.revoke();
    }
};

/// Windows test hook: the hidden top-level window receiving this Watch's
/// notifications, or null when stopped or on other platforms.
pub fn notificationWindowForTesting(watch: *const Watch) ?*anyopaque {
    if (comptime enabled and os == .windows) return windows.notificationWindow(watch);
    return null;
}

/// Backend delivery: never touches the Watch after on_change returns.
pub fn deliver(watch: *Watch, bits: u32) void {
    const app = watch.app orelse return;
    const selected = bits & watch.kinds.bits();
    if (selected == 0) return;
    const scope = app.beginCallback() orelse return;
    defer scope.end();
    watch.on_change(watch.context, Kinds.fromBits(selected));
}

fn nativeChanged(owner: ?*anyopaque, bits: u32) callconv(.c) void {
    const watch: *Watch = @ptrCast(@alignCast(owner orelse return));
    deliver(watch, bits);
}

fn check(value: c_int) !void {
    return switch (value) {
        0 => {},
        1 => error.UnsupportedCapability,
        3 => error.CapacityExceeded,
        4 => error.OutOfMemory,
        5 => error.TooManyMonitors,
        else => error.DesktopQueryFailed,
    };
}

const NativeRect = extern struct { x: i32, y: i32, width: u32, height: u32 };
const NativeMonitor = extern struct { bounds: NativeRect, work: NativeRect, scale: f32, primary: u32, refresh_millihz: u32 };
const NativePreferences = extern struct { scheme: i32, high_contrast: u32, reduce_motion: u32, text_scale: f32 };
const NativePower = extern struct { source: i32, percent: i32, saver: i32 };
const NativeNetwork = extern struct { state: i32, metered: i32 };
extern fn zsd_monitors([*]NativeMonitor, u32, *u32) c_int;
extern fn zsd_preferences(*NativePreferences) c_int;
extern fn zsd_power(*NativePower) c_int;
extern fn zsd_network(*NativeNetwork) c_int;
extern fn zsd_watch_start(u32, *anyopaque, *const fn (?*anyopaque, u32) callconv(.c) void, *?*anyopaque) c_int;
extern fn zsd_watch_stop(*anyopaque) void;
extern fn zsd_resource_count() u32;
extern fn zsd_beep() c_int;
extern fn zsd_cursor(*i32, *i32) c_int;

fn linuxMonitors(staging: *[max_monitors]Monitor) !usize {
    var native: [max_monitors]NativeMonitor = undefined;
    var count: u32 = 0;
    check(zsd_monitors(&native, native.len, &count)) catch |err| return if (err == error.CapacityExceeded) error.TooManyMonitors else err;
    for (native[0..count], staging[0..count]) |source, *out| out.* = .{
        .bounds = .{ .x = source.bounds.x, .y = source.bounds.y, .width = source.bounds.width, .height = source.bounds.height },
        .work_area = .{ .x = source.work.x, .y = source.work.y, .width = source.work.width, .height = source.work.height },
        .scale = source.scale,
        .primary = source.primary != 0,
        .refresh_hz = if (source.refresh_millihz == 0) null else (source.refresh_millihz + 500) / 1000,
    };
    return count;
}
