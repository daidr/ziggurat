//! The permissions the system keeps for the user to give apps, such as
//! Accessibility, Screen Recording and the microphone: checked, asked for
//! with the system's own prompt, and a guide to where the user gives them.
//!
//! macOS keeps them in TCC. `Guide` opens the page of System Settings
//! (Privacy & Security) and, on the pages whose list takes apps dragged into
//! it, shows a panel under the window of System Settings, which follows it,
//! with the app to drag into the list. Windows keeps only the microphone and
//! the camera from desktop apps, with the switches of Settings' Privacy &
//! security pages. Linux keeps none of them for apps outside sandboxes:
//! every call returns UnsupportedCapability there, and `allowed` is true.
//!
//! `check`, `title` and `allowed` are safe on any thread. `Request` and
//! `Guide` start on the App's owner thread, wait on a thread of their own and
//! report on the owner thread; `openSettings` runs on a shell.Worker thread.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const shell = @import("shell.zig");

const os = builtin.os.tag;
const native_macos = os == .macos and !builtin.is_test;
const native_windows = os == .windows and !builtin.is_test;

/// What this build can do. `check` is meaningful only for the permissions
/// each system keeps (see `kept`).
pub const capabilities = .{
    .check = os == .macos or os == .windows,
    // The system's own prompt (macOS only; Windows has none for them).
    .prompt = os == .macos,
    .guide = os == .macos or os == .windows,
    // The panel with the app to drag into System Settings' list.
    .guide_panel = os == .macos,
};

/// Something the system lets the user give apps. The order is System
/// Settings'.
pub const Permission = enum(u8) {
    /// Controlling the computer through the accessibility API: reading other
    /// apps' windows, moving them and sending them input. macOS only; macOS
    /// 27 names it Device Control and Data Access.
    accessibility,
    /// Capturing the screen and its audio. macOS only, which reports a change
    /// only after the app starts again.
    screen_recording,
    /// Reading the keyboard and the mouse while other apps are in front.
    /// macOS only.
    input_monitoring,
    /// Reading the files macOS protects, such as Mail's and Safari's. macOS
    /// has no API for it: `check` tries to read a protected file.
    full_disk_access,
    /// Updating and deleting other apps. macOS only; `check` can't tell.
    app_management,
    /// Running software that doesn't meet the system's security policy, as
    /// debuggers do. macOS only; `check` can't tell.
    developer_tools,
    /// Recording audio: macOS and Windows. Asking on macOS needs
    /// NSMicrophoneUsageDescription in the Info.plist.
    microphone,
    /// Recording video: macOS and Windows. Asking on macOS needs
    /// NSCameraUsageDescription in the Info.plist.
    camera,
    /// The user's calendars. macOS only. Asking needs
    /// NSCalendarsUsageDescription, and NSCalendarsFullAccessUsageDescription
    /// on macOS 14 and later.
    calendars,
    /// The user's reminders. macOS only. Asking needs
    /// NSRemindersUsageDescription, and NSRemindersFullAccessUsageDescription
    /// on macOS 14 and later.
    reminders,
    /// Bluetooth devices. macOS only. Asking needs
    /// NSBluetoothAlwaysUsageDescription in the Info.plist.
    bluetooth,
    /// The user's Apple Music library. macOS only; `check` can't tell.
    media_apple_music,
};

/// Every permission, in the order of System Settings.
pub const all = std.enums.values(Permission);

/// Whether the app has a permission.
pub const Status = enum(u8) {
    /// The system can't tell without asking, or has no API to tell.
    unknown = 0,
    /// The user hasn't been asked yet: `Request` asks. macOS doesn't tell for
    /// Accessibility, Screen Recording and Input Monitoring, which are denied
    /// until granted.
    not_determined = 1,
    /// The user, or the administrator, said no: only the system's settings
    /// change it (see `openSettings` and `Guide`).
    denied = 2,
    granted = 3,
};

pub const Error = error{
    /// The system keeps no such permission for apps.
    UnsupportedCapability,
};

/// The name of the permission as the system's settings show it, in English:
/// "Screen Recording". macOS 27 names Accessibility "Device Control and Data
/// Access".
pub fn title(permission: Permission) []const u8 {
    if (permission == .accessibility and native_macos and zsp_macos_major() >= 27) return "Device Control and Data Access";
    return titleOf(permission);
}
fn titleOf(permission: Permission) []const u8 {
    return switch (permission) {
        .accessibility => "Accessibility",
        .screen_recording => "Screen Recording",
        .input_monitoring => "Input Monitoring",
        .full_disk_access => "Full Disk Access",
        .app_management => "App Management",
        .developer_tools => "Developer Tools",
        .microphone => "Microphone",
        .camera => "Camera",
        .calendars => "Calendars",
        .reminders => "Reminders",
        .bluetooth => "Bluetooth",
        .media_apple_music => "Media & Apple Music",
    };
}

/// Whether this system keeps the permission for apps.
pub fn kept(permission: Permission) bool {
    return switch (os) {
        .macos => true,
        .windows => permission == .microphone or permission == .camera,
        else => false,
    };
}

/// Whether the app has the permission, without asking the user.
/// UnsupportedCapability when the system keeps no such permission for apps;
/// `.unknown` when it does but can't tell.
pub fn check(permission: Permission) Error!Status {
    if (!kept(permission)) return error.UnsupportedCapability;
    if (native_macos) return statusOf(zsp_check(@backingInt(permission)));
    if (native_windows) return windowsCheck(permission);
    return .unknown;
}

/// Whether the app may use what the permission guards: it has it, or the
/// system doesn't ask for it, as Linux doesn't for the microphone.
pub fn allowed(permission: Permission) bool {
    const status = check(permission) catch return true;
    return status == .granted;
}

fn statusOf(value: c_int) Status {
    return switch (value) {
        1 => .not_determined,
        2 => .denied,
        3 => .granted,
        else => .unknown,
    };
}

/// The page of the system's settings where the user gives the permission,
/// null when the system has none.
pub fn settingsUrl(permission: Permission) ?[]const u8 {
    return switch (os) {
        .macos => macSettingsUrl(permission),
        .windows => windowsSettingsUrl(permission),
        else => null,
    };
}
fn macSettingsUrl(permission: Permission) []const u8 {
    const prefix = "x-apple.systempreferences:com.apple.preference.security?";
    return switch (permission) {
        .accessibility => prefix ++ "Privacy_Accessibility",
        .screen_recording => prefix ++ "Privacy_ScreenCapture",
        .input_monitoring => prefix ++ "Privacy_ListenEvent",
        .full_disk_access => prefix ++ "Privacy_AllFiles",
        .app_management => prefix ++ "Privacy_AppBundles",
        .developer_tools => prefix ++ "Privacy_DevTools",
        .microphone => prefix ++ "Privacy_Microphone",
        .camera => prefix ++ "Privacy_Camera",
        .calendars => prefix ++ "Privacy_Calendars",
        .reminders => prefix ++ "Privacy_Reminders",
        .bluetooth => prefix ++ "Privacy_Bluetooth",
        .media_apple_music => prefix ++ "Privacy_Media",
    };
}
fn windowsSettingsUrl(permission: Permission) ?[]const u8 {
    return switch (permission) {
        .microphone => "ms-settings:privacy-microphone",
        .camera => "ms-settings:privacy-webcam",
        else => null,
    };
}
const settings_schemes: []const []const u8 = &.{ "x-apple.systempreferences", "ms-settings" };

/// Whether the list of the permission's page in System Settings takes apps
/// dragged into it, where `Guide` shows its panel. The others list the apps
/// that asked with the system's prompt.
pub fn draggable(permission: Permission) bool {
    return switch (permission) {
        .microphone, .camera, .calendars, .reminders => false,
        else => true,
    };
}

/// Opens the page of the system's settings where the user gives the
/// permission: Privacy & Security in System Settings on macOS, Privacy &
/// security in Settings on Windows. On the worker's thread.
pub fn openSettings(worker: *shell.Worker, permission: Permission) !void {
    const url = settingsUrl(permission) orelse return error.UnsupportedCapability;
    if (!kept(permission)) return error.UnsupportedCapability;
    try worker.openUrl(url, .{ .extra_schemes = settings_schemes });
}

/// Why `Request` or `Guide` failed.
pub const RequestError = error{
    UnsupportedCapability,
    /// The app's Info.plist lacks the description of why it asks, without
    /// which macOS would end the app. Add the key the permission names.
    UsageDescriptionMissing,
};

/// Asks the user for one permission with the system's prompt, when it has one
/// and hasn't asked yet, without blocking the owner thread: `on_done` runs on
/// the owner thread with `status`. macOS asks once for each app; after that
/// the request only reports, and the user changes their mind in System
/// Settings. For permissions without a prompt (Full Disk Access, App
/// Management, Developer Tools, Media & Apple Music, and all of them on
/// Windows) it reports what `check` does. macOS adds the app to the lists of
/// Accessibility, Screen Recording and Input Monitoring when it asks and
/// opens System Settings from its prompt with the switch off: the request
/// ends before the user turns it on (see `Guide`).
///
/// Caller-owned and address-stable from `start` until on_done runs or App
/// shutdown completes; shutdown waits for the thread, then on_done does not
/// run. A request whose user never answers keeps its thread until shutdown.
pub const Request = struct {
    app: ?*z.App = null,
    permission: Permission = .accessibility,
    context: *anyopaque = undefined,
    on_done: *const fn (*anyopaque, *Request) void = undefined,
    thread: ?std.Thread = null,
    stop_node: z.StopParticipant = undefined,
    stop_token: ?z.StopToken = null,
    /// Read in on_done.
    status: Status = .unknown,
    result: RequestError!void = {},
    abandoned: std.atomic.Value(c_int) = .init(0),

    pub fn start(self: *Request, app: *z.App, permission: Permission, context: *anyopaque, on_done: *const fn (*anyopaque, *Request) void) !void {
        app.assertOwner();
        if (self.app != null) return error.Busy;
        if (!kept(permission)) return error.UnsupportedCapability;
        self.* = .{ .app = app, .permission = permission, .context = context, .on_done = on_done };
        self.stop_node = .{ .context = self, .stop = stopped };
        self.stop_token = try app.registerStop(&self.stop_node);
        errdefer {
            _ = app.cancelStop(self.stop_token.?) catch false;
            self.app = null;
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    pub fn pending(self: *const Request) bool {
        return self.app != null;
    }
    fn run(self: *Request) void {
        if (native_macos) {
            var status: c_int = 0;
            switch (zsp_request(@backingInt(self.permission), &self.abandoned.raw, &status)) {
                0 => self.status = statusOf(status),
                1 => {
                    self.status = statusOf(status);
                    self.result = error.UsageDescriptionMissing;
                },
                else => return,
            }
        } else {
            self.status = check(self.permission) catch |err| blk: {
                self.result = err;
                break :blk .unknown;
            };
        }
        postBack(self.app.?, &self.abandoned, self, finish);
    }
    fn finish(ptr: *anyopaque) void {
        const self: *Request = @ptrCast(@alignCast(ptr));
        const app = self.app orelse return;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.stop_token) |token| _ = app.cancelStop(token) catch false;
        self.stop_token = null;
        self.app = null;
        self.on_done(self.context, self);
    }
    fn stopped(ptr: *anyopaque) anyerror!void {
        const self: *Request = @ptrCast(@alignCast(ptr));
        self.stop_token = null;
        self.abandoned.store(1, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.app = null;
    }
};

/// Posts `finish` to the owner thread until it takes it; nothing once the
/// App stops (shutdown waits for the caller's thread).
fn postBack(app: *z.App, abandoned: *std.atomic.Value(c_int), context: *anyopaque, finish: *const fn (*anyopaque) void) void {
    while (abandoned.load(.acquire) == 0) {
        app.post(.{ .context = context, .call = finish }) catch |err| switch (err) {
            error.Full => {
                zio.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return,
        };
        return;
    }
}

pub const GuideOptions = struct {
    /// The path of the app the user drags into System Settings' list on
    /// macOS: the .app bundle the program runs from when null, or the program
    /// itself when it isn't in one (macOS then gives the permission to the app
    /// that started it, such as the terminal, which is the one to drag).
    app: ?[]const u8 = null,
    /// The name the panel gives the app: the app's file name without its
    /// extension when null.
    name: ?[]const u8 = null,
};
pub const max_guide_path_bytes = 1024;
pub const max_guide_name_bytes = 256;

/// How often `Guide` checks the permission.
pub const poll_interval_ms = 250;

/// Opens the page of the system's settings where the user gives the
/// permission and waits, without blocking the owner thread, for the user to
/// give it. On macOS, on the pages whose list takes apps dragged into it (see
/// `draggable`), it also shows a panel under the window of System Settings
/// that follows the window, with the app to drag ("Drag MyApp to the list
/// above to allow Accessibility."). The panel never takes the focus and hides
/// while another app is in front. One panel shows at a time: another Guide
/// ends the one before.
///
/// `on_done` runs on the owner thread with `status` when the app has the
/// permission (when `check` can tell), when the user closes the panel or
/// System Settings, after `cancel`, or when Settings didn't open (`result`).
/// On Windows it ends when the app has the permission or on `cancel`.
/// Caller-owned and address-stable until on_done runs or App shutdown
/// completes; shutdown closes the panel and on_done does not run.
pub const Guide = struct {
    app: ?*z.App = null,
    permission: Permission = .accessibility,
    context: *anyopaque = undefined,
    on_done: *const fn (*anyopaque, *Guide) void = undefined,
    thread: ?std.Thread = null,
    stop_node: z.StopParticipant = undefined,
    stop_token: ?z.StopToken = null,
    native: ?*anyopaque = null,
    status: Status = .unknown,
    result: anyerror!void = {},
    abandoned: std.atomic.Value(c_int) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *Guide, app: *z.App, permission: Permission, options: GuideOptions, context: *anyopaque, on_done: *const fn (*anyopaque, *Guide) void) !void {
        app.assertOwner();
        if (self.app != null) return error.Busy;
        if (!kept(permission) or settingsUrl(permission) == null) return error.UnsupportedCapability;
        var path_buffer: [max_guide_path_bytes + 1]u8 = undefined;
        var name_buffer: [max_guide_name_bytes + 1]u8 = undefined;
        const path = try terminated(&path_buffer, options.app orelse "");
        const name = try terminated(&name_buffer, options.name orelse "");
        self.* = .{ .app = app, .permission = permission, .context = context, .on_done = on_done };
        self.stop_node = .{ .context = self, .stop = stopped };
        self.stop_token = try app.registerStop(&self.stop_node);
        errdefer {
            _ = app.cancelStop(self.stop_token.?) catch false;
            self.app = null;
        }
        if (native_macos) {
            var title_buffer: [64]u8 = undefined;
            const permission_title = try terminated(&title_buffer, title(permission));
            self.native = zsp_guide_start(@backingInt(permission), @intFromBool(draggable(permission)), path, name, permission_title) orelse return error.OutOfMemory;
        }
        errdefer if (self.native) |native| {
            zsp_guide_stop(native);
            self.native = null;
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    pub fn pending(self: *const Guide) bool {
        return self.app != null;
    }
    /// Ends the guide: on_done runs soon after with the status then.
    pub fn cancel(self: *Guide) void {
        self.cancelled.store(true, .release);
    }

    fn run(self: *Guide) void {
        const app = self.app.?;
        opened: {
            var worker = shell.Worker.init(app.owner) catch |err| {
                self.result = err;
                break :opened;
            };
            defer worker.deinit();
            openSettings(&worker, self.permission) catch |err| {
                self.result = err;
            };
        }
        if (self.result) |_| {
            while (self.abandoned.load(.acquire) == 0 and !self.cancelled.load(.acquire)) {
                const status = check(self.permission) catch .unknown;
                if (status == .granted) break;
                if (native_macos and zsp_guide_ended(self.native.?) != 0) break;
                var slept: u32 = 0;
                while (slept < poll_interval_ms and self.abandoned.load(.acquire) == 0 and !self.cancelled.load(.acquire)) : (slept += 10) {
                    zio.sleep(10 * std.time.ns_per_ms);
                }
            }
        } else |_| {}
        if (self.abandoned.load(.acquire) != 0) return;
        self.status = check(self.permission) catch .unknown;
        postBack(app, &self.abandoned, self, finish);
    }
    fn finish(ptr: *anyopaque) void {
        const self: *Guide = @ptrCast(@alignCast(ptr));
        const app = self.app orelse return;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.closeNative();
        if (self.stop_token) |token| _ = app.cancelStop(token) catch false;
        self.stop_token = null;
        self.app = null;
        self.on_done(self.context, self);
    }
    fn closeNative(self: *Guide) void {
        if (native_macos) if (self.native) |native| zsp_guide_stop(native);
        self.native = null;
    }
    fn stopped(ptr: *anyopaque) anyerror!void {
        const self: *Guide = @ptrCast(@alignCast(ptr));
        self.stop_token = null;
        self.abandoned.store(1, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.closeNative();
        self.app = null;
    }
};

fn terminated(buffer: []u8, text: []const u8) ![*:0]const u8 {
    if (text.len >= buffer.len) return error.ArgumentTooLong;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidArgument;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    @memcpy(buffer[0..text.len], text);
    buffer[text.len] = 0;
    return buffer[0..text.len :0];
}

// Windows: the consent store's switches. Any of the device's, the user's, or
// the user's for desktop apps (NonPackaged) set to "Deny" denies it; a switch
// that isn't stored is on.

fn windowsConsent(values: []const ?[]const u16) Status {
    const deny = std.unicode.utf8ToUtf16LeStringLiteral("Deny");
    for (values) |value| {
        const text = value orelse continue;
        if (text.len != deny.len) continue;
        var same = true;
        for (text, deny) |a, b| same = same and std.ascii.toLower(@intCast(a & 0x7f)) == std.ascii.toLower(@intCast(b)) and a < 0x80;
        if (same) return .denied;
    }
    return .granted;
}

fn windowsCheck(permission: Permission) Status {
    @setEvalBranchQuota(10_000);
    const win = @import("ziggurat_c_win32");
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const base = "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\";
    const device, const user = switch (permission) {
        .microphone => .{ L(base ++ "microphone"), L(base ++ "microphone\\NonPackaged") },
        .camera => .{ L(base ++ "webcam"), L(base ++ "webcam\\NonPackaged") },
        else => return .unknown,
    };
    const hklm: win.HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000002)))))));
    const hkcu: win.HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000001)))))));
    var buffers: [3][16]u16 = undefined;
    const Read = struct {
        fn value(root: win.HKEY, key: [*:0]const u16, buffer: *[16]u16) ?[]const u16 {
            var size: win.DWORD = @sizeOf([16]u16);
            if (win.RegGetValueW(root, key, L("Value"), win.RRF_RT_REG_SZ, null, buffer, &size) != 0) return null;
            const units = size / 2;
            return if (units > 0) buffer[0 .. units - 1] else buffer[0..0];
        }
    };
    return windowsConsent(&.{
        Read.value(hklm, device, &buffers[0]),
        Read.value(hkcu, device, &buffers[1]),
        Read.value(hkcu, user, &buffers[2]),
    });
}

// The panel's geometry, plain computation that every platform tests. A Rect
// is in AppKit's screen coordinates: points from the bottom left of the main
// display, y going up, except where it says the window server's.

pub const Rect = extern struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    fn maxX(r: Rect) f64 {
        return r.x + r.w;
    }
    fn maxY(r: Rect) f64 {
        return r.y + r.h;
    }
    fn intersects(r: Rect, o: Rect) bool {
        return r.x < o.maxX() and o.x < r.maxX() and r.y < o.maxY() and o.y < r.maxY();
    }
};
/// A window of System Settings as the window server tells of it.
pub const SettingsWindow = extern struct { bounds: Rect, layer: i32, alpha: f64 };

/// The width of System Settings' sidebar: the panel lines up with the page on
/// its right, where the list is.
pub const settings_sidebar = 230;
pub const panel_min_width = 240;
pub const screen_inset = 12;

/// Converts a rectangle from the window server's coordinates (top left of
/// the main display, y going down) to AppKit's.
pub fn flipRect(r: Rect, main_height: f64) Rect {
    return .{ .x = r.x, .y = main_height - r.y - r.h, .w = r.w, .h = r.h };
}
/// The panel's width under System Settings' window, on the visible part of
/// a screen.
pub fn panelWidth(settings: Rect, screen: Rect) f64 {
    return @min(@max(panel_min_width, settings.w - settings_sidebar), screen.w - 2 * screen_inset);
}
/// Places a panel of the height under System Settings' window: aligned with
/// its page, right under it, kept inside the screen, over the bottom of the
/// window when there's no room under it.
pub fn panelFrame(settings: Rect, screen: Rect, height: f64) Rect {
    const w = panelWidth(settings, screen);
    const x = @max(screen.x + screen_inset, @min(settings.x + settings_sidebar, screen.maxX() - w - screen_inset));
    const y = @max(screen.y + screen_inset, @min(settings.y - height, screen.maxY() - height - screen_inset));
    return .{ .x = x, .y = y, .w = w, .h = height };
}
/// The visible part of the screen that shows most of r, or the first one
/// when none does.
pub fn screenOf(r: Rect, screens: []const Rect) Rect {
    var best: Rect = .{};
    var area: f64 = -1;
    for (screens, 0..) |s, i| {
        if (i == 0) best = s;
        if (!r.intersects(s)) continue;
        const w = @min(r.maxX(), s.maxX()) - @max(r.x, s.x);
        const h = @min(r.maxY(), s.maxY()) - @max(r.y, s.y);
        if (w * h > area) {
            best = s;
            area = w * h;
        }
    }
    return best;
}
/// System Settings' window among its windows: the largest of the normal
/// layer that shows, leaving out its small helper windows.
pub fn mainSettingsWindow(windows: []const SettingsWindow) ?Rect {
    var best: ?Rect = null;
    for (windows) |w| {
        if (w.layer != 0 or w.alpha <= 0 or w.bounds.w <= 320 or w.bounds.h <= 240) continue;
        if (best == null or w.bounds.w * w.bounds.h > best.?.w * best.?.h) best = w.bounds;
    }
    return best;
}
/// The name the panel gives the app at a path: its file name without the
/// extension.
pub fn appName(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const base = trimmed[if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| slash + 1 else 0..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
}

// The macOS panel calls the geometry above.
fn exportedPanelFrame(settings: Rect, main_height: f64, screens: [*]const Rect, count: usize, height: f64) callconv(.c) Rect {
    const flipped = flipRect(settings, main_height);
    return panelFrame(flipped, screenOf(flipped, screens[0..count]), height);
}
fn exportedPanelWidth(settings: Rect, main_height: f64, screens: [*]const Rect, count: usize) callconv(.c) f64 {
    const flipped = flipRect(settings, main_height);
    return panelWidth(flipped, screenOf(flipped, screens[0..count]));
}
fn exportedMainWindow(windows: [*]const SettingsWindow, count: usize, out: *Rect) callconv(.c) c_int {
    out.* = mainSettingsWindow(windows[0..count]) orelse return 0;
    return 1;
}
comptime {
    // The test build links the panel too.
    if (os == .macos) {
        @export(&exportedPanelFrame, .{ .name = "zsp_panel_frame" });
        @export(&exportedPanelWidth, .{ .name = "zsp_panel_width" });
        @export(&exportedMainWindow, .{ .name = "zsp_main_settings_window" });
    }
}

extern fn zsp_macos_major() c_int;
extern fn zsp_check(c_int) c_int;
extern fn zsp_request(c_int, *c_int, *c_int) c_int;
extern fn zsp_guide_start(c_int, c_int, [*:0]const u8, [*:0]const u8, [*:0]const u8) ?*anyopaque;
extern fn zsp_guide_ended(*anyopaque) c_int;
extern fn zsp_guide_stop(*anyopaque) void;

test "settings pages and titles" {
    try std.testing.expectEqual(12, all.len);
    try std.testing.expectEqualStrings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", macSettingsUrl(.screen_recording));
    try std.testing.expectEqualStrings("ms-settings:privacy-webcam", windowsSettingsUrl(.camera).?);
    try std.testing.expect(windowsSettingsUrl(.accessibility) == null);
    try std.testing.expectEqualStrings("Media & Apple Music", titleOf(.media_apple_music));
    for (all) |p| try shell.validateUrl(macSettingsUrl(p), settings_schemes);
    try shell.validateUrl(windowsSettingsUrl(.microphone).?, settings_schemes);
    try std.testing.expect(!draggable(.camera) and draggable(.accessibility) and draggable(.bluetooth));
}

test "consent store" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqual(Status.granted, windowsConsent(&.{ null, null, null }));
    try std.testing.expectEqual(Status.granted, windowsConsent(&.{ L("Allow"), null, L("Allow") }));
    try std.testing.expectEqual(Status.denied, windowsConsent(&.{ L("Allow"), L("deny"), null }));
    try std.testing.expectEqual(Status.denied, windowsConsent(&.{ null, null, L("Deny") }));
}

test "app names" {
    try std.testing.expectEqualStrings("MyApp", appName("/Applications/MyApp.app"));
    try std.testing.expectEqualStrings("MyApp", appName("/Applications/MyApp.app/"));
    try std.testing.expectEqualStrings("tool", appName("/tmp/tool"));
    try std.testing.expectEqualStrings(".hidden", appName("/tmp/.hidden"));
}

test "panel geometry" {
    const screen: Rect = .{ .x = 0, .y = 0, .w = 1440, .h = 875 };
    // Under the page, right of the sidebar.
    const settings: Rect = .{ .x = 200, .y = 300, .w = 715, .h = 500 };
    try std.testing.expectEqual(Rect{ .x = 430, .y = 200, .w = 485, .h = 100 }, panelFrame(settings, screen, 100));
    // At the bottom of the screen it goes over the window.
    const low: Rect = .{ .x = 200, .y = 5, .w = 715, .h = 500 };
    try std.testing.expectEqual(@as(f64, screen_inset), panelFrame(low, screen, 100).y);
    // Narrow windows still get the minimum width; the screen bounds it.
    try std.testing.expectEqual(@as(f64, panel_min_width), panelWidth(.{ .w = 300, .h = 400 }, screen));
    try std.testing.expectEqual(@as(f64, 200 - 2 * screen_inset), panelWidth(.{ .w = 900, .h = 400 }, .{ .w = 200, .h = 400 }));
    // Kept inside the right edge.
    const right = panelFrame(.{ .x = 1300, .y = 300, .w = 715, .h = 500 }, screen, 100);
    try std.testing.expectEqual(screen.maxX() - right.w - screen_inset, right.x);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 875 - 20 - 30, .w = 40, .h = 30 }, flipRect(.{ .x = 10, .y = 20, .w = 40, .h = 30 }, 875));
}

test "screens and windows" {
    const screens = [_]Rect{ .{ .w = 1440, .h = 875 }, .{ .x = 1440, .w = 1920, .h = 1080 } };
    try std.testing.expectEqual(screens[1], screenOf(.{ .x = 1400, .y = 100, .w = 600, .h = 400 }, &screens));
    try std.testing.expectEqual(screens[0], screenOf(.{ .x = 100, .y = 100, .w = 600, .h = 400 }, &screens));
    try std.testing.expectEqual(screens[0], screenOf(.{ .x = -5000, .y = 100, .w = 60, .h = 40 }, &screens));
    const windows = [_]SettingsWindow{
        .{ .bounds = .{ .w = 715, .h = 500 }, .layer = 0, .alpha = 1 },
        .{ .bounds = .{ .w = 900, .h = 700 }, .layer = 0, .alpha = 0 },
        .{ .bounds = .{ .w = 900, .h = 700 }, .layer = 3, .alpha = 1 },
        .{ .bounds = .{ .w = 300, .h = 700 }, .layer = 0, .alpha = 1 },
        .{ .bounds = .{ .x = 5, .w = 800, .h = 600 }, .layer = 0, .alpha = 1 },
    };
    try std.testing.expectEqual(windows[4].bounds, mainSettingsWindow(&windows).?);
    try std.testing.expect(mainSettingsWindow(windows[1..4]) == null);
}

test "unsupported systems" {
    if (os == .macos or os == .windows) return error.SkipZigTest;
    try std.testing.expectError(error.UnsupportedCapability, check(.microphone));
    try std.testing.expect(allowed(.microphone));
    try std.testing.expect(settingsUrl(.camera) == null);
}

test "windows consent store reader compiles" {
    if (os != .windows) return error.SkipZigTest;
    _ = &windowsCheck;
}
