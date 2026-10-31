const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const native = if (builtin.is_test) Unsupported else if (builtin.os.tag == .windows) @import("drop_windows.zig") else if (builtin.os.tag == .linux) Linux else Unsupported;

pub const capabilities = .{
    .drop_target = native.supported,
    // Starting a native drag runs a modal OLE/GTK drag loop on Windows and a
    // pointer grab with nested dispatch, so no drag source is offered.
    .drag_source = false,
};

pub const Kinds = struct { files: bool = true, text: bool = true };
pub const Phase = enum { enter, over, leave };
/// Client point in DIP. `files`/`text` describe what the source offers that
/// this Target accepts; a leave carries the last known point.
pub const Hover = struct { phase: Phase, point: z.Point, files: bool, text: bool };
/// files use the clipboard convention: absolute UTF-8 paths separated by one
/// NUL byte. Data borrows Target.buffer only for the duration of on_drop.
pub const Payload = union(enum) {
    files: []const u8,
    text: []const u8,
    capacity_exceeded: usize,
    failed: Failure,
};
pub const Failure = struct { err: error{ DropMalformed, InvalidUtf16, TooManyFiles, NativeFailure }, code: u32 = 0 };
pub const Drop = struct { point: z.Point, payload: Payload };
pub const max_files = 1024;

/// A native drop target on one window. Keep at a stable address while attached
/// and its context valid through detach or the window's on_closed. Callbacks run
/// on the owner thread inside a window callback scope. on_hover returns whether
/// the drop is accepted at that point; a null on_hover accepts every offered
/// kind. Every hover sequence ends with leave, which also precedes on_drop.
pub const Target = struct {
    context: *anyopaque,
    on_drop: *const fn (*anyopaque, z.Window, Drop) void,
    on_hover: ?*const fn (*anyopaque, z.Window, Hover) bool = null,
    kinds: Kinds = .{},
    /// Caller storage for payload bytes. Larger payloads report the size.
    buffer: []u8,
    window: ?z.Window = null,
    native: ?*anyopaque = null,
    last_error: u32 = 0,

    pub fn attach(self: *Target, window: z.Window) !void {
        window.app.assertOwner();
        if (!native.supported) return error.UnsupportedCapability;
        if (self.window != null) return error.AlreadyAttached;
        if (!self.kinds.files and !self.kinds.text) return error.InvalidKinds;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const handle = window.nativeHandle() orelse return error.Closed;
        self.native = try native.attach(self, handle);
        self.window = window;
    }
    /// Idempotent. Revokes native registration if the window still exists; a
    /// closed window already revoked it before native destruction.
    pub fn detach(self: *Target) void {
        const window = self.window orelse return;
        window.app.assertOwner();
        native.detach(self.native.?);
        self.native = null;
        self.window = null;
    }

    /// Whether the window currently carries a native drop registration, as the
    /// system reports it. False after detach or native window destruction.
    pub fn registered(window: z.Window) bool {
        window.app.assertOwner();
        const handle = window.nativeHandle() orelse return false;
        return native.registered(handle);
    }
    /// Native adapter entry for hover phases.
    pub fn hover(self: *Target, value: Hover) bool {
        const window = self.window orelse return false;
        const scope = window.beginCallback() orelse return false;
        defer scope.end();
        const accepted = if (self.on_hover) |callback| callback(self.context, window, value) else true;
        return accepted and (value.files or value.text);
    }
    /// Native adapter entry. Bytes are copied into buffer before on_drop.
    pub fn drop(self: *Target, point: z.Point, payload: Payload) void {
        const window = self.window orelse return;
        const scope = window.beginCallback() orelse return;
        defer scope.end();
        const delivered: Payload = switch (payload) {
            .files, .text => |bytes| copied: {
                if (bytes.len > self.buffer.len) break :copied .{ .capacity_exceeded = bytes.len };
                @memcpy(self.buffer[0..bytes.len], bytes);
                break :copied if (payload == .files) .{ .files = self.buffer[0..bytes.len] } else .{ .text = self.buffer[0..bytes.len] };
            },
            else => payload,
        };
        self.on_drop(self.context, window, .{ .point = point, .payload = delivered });
    }
};

const Unsupported = struct {
    const supported = false;
    fn attach(_: *Target, _: *anyopaque) !*anyopaque {
        return error.UnsupportedCapability;
    }
    fn detach(_: *anyopaque) void {}
    fn registered(_: *anyopaque) bool {
        return false;
    }
};

const Linux = struct {
    const supported = true;
    const Callbacks = extern struct {
        hover: *const fn (?*anyopaque, c_int, f64, f64, c_int, c_int) callconv(.c) c_int,
        drop: *const fn (?*anyopaque, f64, f64, c_int, ?[*]const u8, usize) callconv(.c) void,
    };
    extern fn zsd_attach(widget: *anyopaque, owner: *anyopaque, callbacks: *const Callbacks, files: c_int, text: c_int) ?*anyopaque;
    extern fn zsd_detach(target: *anyopaque) void;
    extern fn zsd_registered(widget: *anyopaque) c_int;
    fn registered(handle: *anyopaque) bool {
        return zsd_registered(handle) != 0;
    }
    const callbacks: Callbacks = .{ .hover = hoverNative, .drop = dropNative };
    fn attach(target: *Target, handle: *anyopaque) !*anyopaque {
        return zsd_attach(handle, target, &callbacks, @intFromBool(target.kinds.files), @intFromBool(target.kinds.text)) orelse error.OutOfMemory;
    }
    fn detach(state: *anyopaque) void {
        zsd_detach(state);
    }
    fn owner(pointer: ?*anyopaque) *Target {
        return @ptrCast(@alignCast(pointer.?));
    }
    fn hoverNative(pointer: ?*anyopaque, phase: c_int, x: f64, y: f64, files: c_int, text: c_int) callconv(.c) c_int {
        const value: Hover = .{ .phase = @fromBackingInt(@intCast(zio.asUnsigned(phase))), .point = .{ .x = @floatCast(x), .y = @floatCast(y) }, .files = files != 0, .text = text != 0 };
        return @intFromBool(owner(pointer).hover(value));
    }
    fn dropNative(pointer: ?*anyopaque, x: f64, y: f64, status: c_int, data: ?[*]const u8, len: usize) callconv(.c) void {
        const bytes: []const u8 = if (data) |value| value[0..len] else &.{};
        const point: z.Point = .{ .x = @floatCast(x), .y = @floatCast(y) };
        owner(pointer).drop(point, switch (status) {
            0 => .{ .files = bytes },
            1 => .{ .text = bytes },
            2 => .{ .failed = .{ .err = error.TooManyFiles } },
            else => .{ .failed = .{ .err = error.DropMalformed } },
        });
    }
};
