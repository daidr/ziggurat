//! Native drags out of a window: the system's drag session carries a
//! transfer.Data to other windows and applications, with copy or move
//! negotiated with the destination.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const transfer = @import("transfer.zig");
const desktop = @import("desktop.zig");

const os = builtin.os.tag;
const native_supported = !builtin.is_test and (os == .windows or os == .linux or os == .macos);
const native = if (!native_supported) Unsupported else if (os == .windows) @import("drag_windows.zig") else Linux;

pub const capabilities = .{ .source = native_supported, .preview = native_supported };

/// Straight-alpha RGBA8 rows, top first. One pixel is one DIP.
pub const Preview = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    /// The pointer's offset in the image, in pixels.
    hotspot_x: i32 = 0,
    hotspot_y: i32 = 0,
};
pub const max_preview_size = 4096;

/// The destination's final effect. `.none` means nothing was dropped.
pub const Result = struct {
    operation: transfer.Operation = .none,
    /// The drag ended without a drop: let go over no target, or given up.
    canceled: bool = false,
    /// A canceled drag was given up (Escape, `cancel`, the source window
    /// closing or App shutdown) rather than let go over no target.
    escaped: bool = false,
    /// Where the drag ended, in desktop coordinates as
    /// `desktop.cursorPosition` reports them.
    point: z.ScreenPoint = .{ .x = 0, .y = 0 },
    /// A native or provider failure; the operation is then `.none`.
    err: ?anyerror = null,
};

pub const Options = struct {
    /// Effects the source allows; empty means copy.
    operations: transfer.Operations = .{},
    /// Copied at start. Null leaves the system's default drag feedback.
    preview: ?Preview = null,
    context: ?*anyopaque = null,
    /// Runs on the owner thread exactly once for a started drag, including
    /// cancellation, native start failure, the source window closing and
    /// App shutdown. Remove the original only after a `.move`; nothing is
    /// ever deleted for the app.
    on_done: ?*const fn (?*anyopaque, *Source, Result) void = null,
};

var active: ?*Source = null;
var started: u64 = 0;

/// The drag in progress in this process, if any.
pub fn current() ?*Source {
    return active;
}

/// One native drag. Caller-owned and address-stable from `start` until
/// on_done has run; lazy providers in the data and the options' context stay
/// valid as long. Owner thread only. One drag runs at a time per process.
pub const Source = struct {
    allocator: std.mem.Allocator = undefined,
    app: ?*z.App = null,
    window: z.Window = undefined,
    snapshot: transfer.Snapshot = undefined,
    options: Options = .{},
    operations: transfer.Operations = .{},
    pixels: []u8 = &.{},
    state: enum { idle, scheduled, running } = .idle,
    /// Distinguishes this drag from later ones at the same address.
    id: u64 = 0,
    escaped: bool = false,
    native_error: ?anyerror = null,
    stop_node: z.StopParticipant = undefined,
    stop_token: ?z.StopToken = null,
    native: native.State = .{},

    /// Starts a drag from the window's current pointer gesture: call it
    /// while handling a pointer press or move with a button held. It returns
    /// after scheduling the drag; the native session begins once the input
    /// callback has returned, so input and frames are never suspended
    /// halfway through one. The data is copied into a Snapshot with
    /// `allocator`. Errors here start nothing and on_done does not run.
    pub fn start(self: *Source, allocator: std.mem.Allocator, window: z.Window, data: transfer.Data, options: Options) !void {
        window.app.assertOwner();
        if (comptime !native_supported) return error.UnsupportedCapability;
        if (self.state != .idle) return error.AlreadyStarted;
        if (active != null) return error.DragActive;
        if (window.isClosed() or window.nativeHandle() == null) return error.Closed;
        if (data.items.len == 0) return error.FormatUnavailable;
        if (options.preview) |preview| try validatePreview(preview);
        var snapshot = try transfer.Snapshot.init(allocator, data);
        errdefer snapshot.deinit();
        const pixels: []u8 = if (options.preview) |preview| try allocator.dupe(u8, preview.pixels) else &.{};
        errdefer allocator.free(pixels);
        self.* = .{
            .allocator = allocator,
            .app = window.app,
            .window = window,
            .snapshot = snapshot,
            .options = options,
            .operations = options.operations.allowed(),
            .pixels = pixels,
            .state = .scheduled,
            .id = started + 1,
        };
        started += 1;
        self.stop_node = .{ .context = self, .stop = stopped };
        self.stop_token = try window.app.registerStop(&self.stop_node);
        errdefer {
            _ = window.app.cancelStop(self.stop_token.?) catch false;
            self.stop_token = null;
            self.state = .idle;
        }
        try native.schedule(self);
        active = self;
    }
    /// Gives the drag up: on_done reports it canceled and escaped. Nothing
    /// happens without a drag.
    pub fn cancel(self: *Source) void {
        if (self.state == .idle) return;
        self.app.?.assertOwner();
        self.escaped = true;
        native.cancel(self);
        self.finish(.{ .canceled = true, .escaped = true });
    }
    pub fn running(self: *const Source) bool {
        return self.state != .idle;
    }
    pub fn previewImage(self: *const Source) ?Preview {
        const value = self.options.preview orelse return null;
        return .{ .pixels = self.pixels, .width = value.width, .height = value.height, .hotspot_x = value.hotspot_x, .hotspot_y = value.hotspot_y };
    }

    /// Native adapter entry: the scheduled drag, if its session may begin
    /// now. Scheduling messages name no Source, so one that outlived its
    /// drag finds nothing here.
    pub fn beginScheduled() ?*Source {
        const self = active orelse return null;
        if (self.state != .scheduled) return null;
        if (self.window.isClosed() or self.window.nativeHandle() == null) {
            self.finish(.{ .canceled = true, .escaped = true });
            return null;
        }
        self.state = .running;
        return self;
    }
    /// Native adapter entry: the rendered bytes of a format, borrowed from
    /// the Snapshot until the drag ends.
    pub fn render(self: *Source, format: transfer.Format) ![]const u8 {
        if (self.state != .running) return error.Closed;
        return self.snapshot.read(format);
    }
    /// Native adapter entry, once per session. Normalizes the result as
    /// on_done receives it.
    pub fn finish(self: *Source, outcome: Result) void {
        if (self.state == .idle) return;
        const app = self.app.?;
        var result = outcome;
        if (result.operation != .none and !self.operations.has(result.operation)) result = .{ .err = error.DisallowedOperation };
        if (result.err != null or result.canceled) result.operation = .none;
        if (result.operation == .none and result.err == null) result.canceled = true;
        result.escaped = result.canceled and (result.escaped or self.escaped);
        result.point = desktop.cursorPosition(app) catch outcome.point;
        if (active == self) active = null;
        self.state = .idle;
        if (self.stop_token) |token| _ = app.cancelStop(token) catch false;
        self.stop_token = null;
        self.snapshot.deinit();
        self.allocator.free(self.pixels);
        self.pixels = &.{};
        self.app = null;
        if (self.options.on_done) |on_done| on_done(self.options.context, self, result);
    }
    fn stopped(ptr: *anyopaque) anyerror!void {
        const self: *Source = @ptrCast(@alignCast(ptr));
        self.stop_token = null;
        self.cancel();
    }
};

fn validatePreview(value: Preview) !void {
    if (value.width == 0 or value.height == 0 or value.width > max_preview_size or value.height > max_preview_size) return error.InvalidPreview;
    if (value.pixels.len != @as(usize, value.width) * value.height * 4) return error.InvalidPreview;
}

/// The drag of this process whose native session is `session`, for drop
/// targets that keep every item of a local drag.
pub fn local(session: ?*anyopaque) ?*Source {
    const source = active orelse return null;
    if (source.state != .running or session == null or !native.owns(source, session.?)) return null;
    return source;
}

const Unsupported = struct {
    const State = struct {};
    fn schedule(_: *Source) !void {
        return error.UnsupportedCapability;
    }
    fn cancel(_: *Source) void {}
    fn owns(_: *Source, _: *anyopaque) bool {
        return false;
    }
};

/// GTK maps formats to selection targets: text also as UTF8_STRING and
/// text/plain;charset=utf-8, file lists as text/uri-list.
pub const gtk = struct {
    pub fn targetFormat(name: []const u8, offered: transfer.Data) transfer.Format {
        if (std.mem.eql(u8, name, "UTF8_STRING") or std.mem.eql(u8, name, "text/plain;charset=utf-8")) return transfer.text;
        if (std.mem.eql(u8, name, transfer.uri_list) and !offered.offers(transfer.uri_list)) return transfer.file_list;
        return name;
    }
    /// NUL-terminated target names for the data's formats.
    pub fn targets(allocator: std.mem.Allocator, data: transfer.Data) !std.ArrayList(u8) {
        var names: std.ArrayList(u8) = .empty;
        errdefer names.deinit(allocator);
        var formats: [transfer.max_formats * 4]transfer.Format = undefined;
        const count = data.formats(&formats);
        var listed: [transfer.max_formats * 4 + 2][]const u8 = undefined;
        var listed_count: usize = 0;
        for (formats[0..count]) |format| {
            const name = if (std.mem.eql(u8, format, transfer.file_list)) transfer.uri_list else format;
            const extra: []const []const u8 = if (std.mem.eql(u8, format, transfer.text)) &.{ "UTF8_STRING", "text/plain;charset=utf-8" } else &.{};
            try add(allocator, &names, &listed, &listed_count, name);
            for (extra) |more| try add(allocator, &names, &listed, &listed_count, more);
        }
        return names;
    }
    fn add(allocator: std.mem.Allocator, names: *std.ArrayList(u8), listed: [][]const u8, count: *usize, name: []const u8) !void {
        for (listed[0..count.*]) |existing| if (std.mem.eql(u8, existing, name)) return;
        if (count.* == listed.len) return;
        listed[count.*] = name;
        count.* += 1;
        try names.appendSlice(allocator, name);
        try names.append(allocator, 0);
    }
};

/// GTK, and AppKit through src/system/macos_drag.m with the same entry points.
const Linux = struct {
    const State = struct { event: ?*anyopaque = null, session: ?*anyopaque = null };
    const Callbacks = extern struct {
        get: *const fn (?*anyopaque, [*:0]const u8, *?[*]const u8, *usize) callconv(.c) c_int,
        end: *const fn (?*anyopaque, c_int, c_int, c_int) callconv(.c) void,
    };
    extern fn zst_current_event() ?*anyopaque;
    extern fn zst_event_free(event: *anyopaque) void;
    extern fn zst_source_begin(widget: *anyopaque, event: *anyopaque, names: [*]const u8, names_len: usize, actions: c_int, rgba: ?[*]const u8, width: c_int, height: c_int, hot_x: c_int, hot_y: c_int, owner: *anyopaque, callbacks: *const Callbacks) ?*anyopaque;
    extern fn zst_source_cancel(session: *anyopaque) void;
    const callbacks: Callbacks = .{ .get = get, .end = end };

    fn schedule(source: *Source) !void {
        // GTK starts a drag from the event that holds the button.
        const event = zst_current_event() orelse return error.NoPointerGesture;
        errdefer zst_event_free(event);
        source.native = .{ .event = event };
        try source.window.app.post(.{ .context = &scheduled, .call = run });
    }
    var scheduled: u8 = 0;
    fn run(_: *anyopaque) void {
        const source = Source.beginScheduled() orelse return;
        const event = source.native.event.?;
        source.native.event = null;
        defer zst_event_free(event);
        var names = gtk.targets(source.allocator, source.snapshot.data()) catch |err| return source.finish(.{ .err = err });
        defer names.deinit(source.allocator);
        const value = source.previewImage();
        const session = zst_source_begin(source.window.nativeHandle().?, event, names.items.ptr, names.items.len, actions(source.operations), if (value) |p| p.pixels.ptr else null, if (value) |p| @intCast(p.width) else 0, if (value) |p| @intCast(p.height) else 0, if (value) |p| p.hotspot_x else 0, if (value) |p| p.hotspot_y else 0, source, &callbacks) orelse
            return source.finish(.{ .err = error.DragStartFailed });
        source.native.session = session;
    }
    fn cancel(source: *Source) void {
        if (source.native.event) |event| zst_event_free(event);
        if (source.native.session) |session| zst_source_cancel(session);
        source.native = .{};
    }
    extern fn zst_session_is(session: ?*anyopaque, context: *anyopaque) c_int;
    fn owns(source: *Source, context: *anyopaque) bool {
        return zst_session_is(source.native.session, context) != 0;
    }
    fn actions(operations: transfer.Operations) c_int {
        return (if (operations.copy) @as(c_int, 2) else 0) | (if (operations.move) @as(c_int, 4) else 0);
    }
    fn owner(pointer: ?*anyopaque) *Source {
        return @ptrCast(@alignCast(pointer.?));
    }
    fn get(pointer: ?*anyopaque, name: [*:0]const u8, data: *?[*]const u8, len: *usize) callconv(.c) c_int {
        const source = owner(pointer);
        const bytes = source.render(gtk.targetFormat(std.mem.span(name), source.snapshot.data())) catch |err| {
            source.native_error = err;
            return -1;
        };
        data.* = bytes.ptr;
        len.* = bytes.len;
        return 0;
    }
    /// status: 0 dropped, 1 no target, 2 given up, 3 failed.
    fn end(pointer: ?*anyopaque, action: c_int, status: c_int, escaped: c_int) callconv(.c) void {
        const source = owner(pointer);
        source.native.session = null;
        const operation: transfer.Operation = if (action & 4 != 0) .move else if (action & 2 != 0) .copy else .none;
        const failure: ?anyerror = if (source.native_error) |err| err else if (status == 3) error.DragFailed else null;
        source.finish(.{ .operation = if (status == 0) operation else .none, .canceled = status == 1 or status == 2, .escaped = escaped != 0 or status == 2, .err = failure });
    }
};

test "gtk targets name text and file lists as GTK expects" {
    const items = [_]transfer.Item{
        .{ .representations = &.{ .fromBytes(transfer.text, "a"), .fromBytes(transfer.file_list, "file:///a") } },
        .{ .representations = &.{.fromBytes("application/x-note", "{}")} },
    };
    const data: transfer.Data = .{ .items = &items };
    var names = try gtk.targets(std.testing.allocator, data);
    defer names.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("text/plain\x00UTF8_STRING\x00text/plain;charset=utf-8\x00text/uri-list\x00application/x-note\x00", names.items);
    try std.testing.expectEqualStrings(transfer.file_list, gtk.targetFormat("text/uri-list", data));
    try std.testing.expectEqualStrings(transfer.text, gtk.targetFormat("UTF8_STRING", data));
}
