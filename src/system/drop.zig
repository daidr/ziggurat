const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const transfer = @import("transfer.zig");
const drag = @import("drag.zig");
const native = if (builtin.is_test) Unsupported else if (builtin.os.tag == .windows) @import("drop_windows.zig") else if (builtin.os.tag == .linux) Linux else Unsupported;

pub const capabilities = .{
    .drop_target = native.supported,
    .data_target = native.supported,
    .drag_source = drag.capabilities.source,
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

/// A data drag over a DataTarget. `operation` is the effect negotiated for
/// the offer; on_hover may still refuse it.
pub const DataHover = struct {
    phase: Phase,
    point: z.Point,
    offer: transfer.Offer,
    operation: transfer.Operation,
    /// The drag comes from this process.
    local: bool,
};
/// `data` holds the accepted formats the source offered. It borrows the
/// target's storage only during on_drop; copy what must outlive it.
pub const DataDrop = struct {
    point: z.Point,
    data: transfer.Data,
    operation: transfer.Operation,
    local: bool,
};
pub const max_offer_bytes = 16 * 1024;

/// A native multi-format drop target on one window. It takes a drag when
/// the source offers at least one of `formats` and both ends share an
/// operation (empty `operations` means copy); the source's modifier-key
/// suggestion wins, otherwise copy comes before move. Hover reads no
/// bytes. On drop the accepted formats are requested; a drag from this
/// process keeps all its items, other sources arrive as one item. Text and
/// URI lists from GTK and OLE follow transfer.Data.read's coalescing.
/// Keep at a stable address while attached; context stays valid through
/// detach or the window's on_closed. A window takes one drop target of
/// either kind.
pub const DataTarget = struct {
    context: *anyopaque,
    /// Returns whether the drop was taken; the source then sees the
    /// operation, otherwise none.
    on_drop: *const fn (*anyopaque, z.Window, DataDrop) bool,
    on_hover: ?*const fn (*anyopaque, z.Window, DataHover) bool = null,
    /// Accepted formats, in the receiver's preference order.
    formats: []const transfer.Format,
    operations: transfer.Operations = .{},
    /// Received bytes, freed after on_drop.
    allocator: std.mem.Allocator,
    window: ?z.Window = null,
    native: ?*anyopaque = null,
    last_error: u32 = 0,
    names: [max_offer_bytes]u8 = undefined,
    names_len: usize = 0,
    offered: [transfer.max_formats]transfer.Format = undefined,
    offered_count: usize = 0,
    wanted: [transfer.max_formats]Wanted = undefined,
    wanted_count: usize = 0,
    pending: ?Pending = null,

    pub const Wanted = struct { format: transfer.Format, native: []const u8 };
    const Pending = struct {
        builder: transfer.Builder,
        point: z.Point,
        operation: transfer.Operation,
        failed: bool = false,
        local: ?transfer.Owned = null,

        fn deinit(self: *Pending) void {
            self.builder.deinit();
            if (self.local) |*owned| owned.deinit();
        }
    };

    pub fn attach(self: *DataTarget, window: z.Window) !void {
        window.app.assertOwner();
        if (!native.supported) return error.UnsupportedCapability;
        if (self.window != null) return error.AlreadyAttached;
        if (self.formats.len == 0 or self.formats.len > transfer.max_formats) return error.InvalidFormats;
        for (self.formats) |format| if (!transfer.validFormat(format)) return error.InvalidFormats;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const handle = window.nativeHandle() orelse return error.Closed;
        self.native = try native.dataAttach(self, handle);
        self.window = window;
    }
    /// Idempotent, as Target.detach.
    pub fn detach(self: *DataTarget) void {
        const window = self.window orelse return;
        window.app.assertOwner();
        native.dataDetach(self.native.?);
        self.native = null;
        self.window = null;
        self.dropPending();
    }

    /// Native adapter entry: starts a new offer list.
    pub fn clearOffer(self: *DataTarget) void {
        self.names_len = 0;
        self.offered_count = 0;
    }
    /// Native adapter entry: adds an offered format, copied. Duplicates and
    /// invalid names are skipped.
    pub fn addOffer(self: *DataTarget, format: transfer.Format) void {
        if (!transfer.validFormat(format) or self.offers(format)) return;
        if (self.offered_count == self.offered.len or self.names_len + format.len > self.names.len) return;
        const copy = self.names[self.names_len..][0..format.len];
        @memcpy(copy, format);
        self.names_len += format.len;
        self.offered[self.offered_count] = copy;
        self.offered_count += 1;
    }
    pub fn offers(self: *const DataTarget, format: transfer.Format) bool {
        for (self.offered[0..self.offered_count]) |existing| if (std.mem.eql(u8, existing, format)) return true;
        return false;
    }
    fn negotiated(self: *const DataTarget, operations: transfer.Operations, suggested: transfer.Operation) transfer.Operation {
        var matched = false;
        for (self.formats) |format| matched = matched or self.offers(format);
        if (!matched) return .none;
        return transfer.negotiate(operations, self.operations, suggested);
    }
    /// Native adapter entry for hover phases, after the offer was set.
    /// Returns the effect to report.
    pub fn hover(self: *DataTarget, phase: Phase, point: z.Point, operations: transfer.Operations, suggested: transfer.Operation, session: ?*anyopaque) transfer.Operation {
        const window = self.window orelse return .none;
        const scope = window.beginCallback() orelse return .none;
        defer scope.end();
        const operation = if (phase == .leave) .none else self.negotiated(operations, suggested);
        const value: DataHover = .{ .phase = phase, .point = point, .offer = .{ .formats = self.offered[0..self.offered_count], .operations = operations, .suggested = suggested }, .operation = operation, .local = drag.local(session) != null };
        const accepted = if (self.on_hover) |callback| callback(self.context, window, value) else true;
        return if (accepted) operation else .none;
    }
    /// Native adapter entry for a drop, after the offer was set. Returns
    /// the negotiated operation, or none to refuse. With an operation and a
    /// nonempty `wanted()`, the native side requests each wanted native
    /// format, calls `receive` for each, then `complete`; with an empty
    /// one (a local drag) the drop was already delivered and `complete`
    /// reports it.
    pub fn beginDrop(self: *DataTarget, point: z.Point, operations: transfer.Operations, suggested: transfer.Operation, session: ?*anyopaque, comptime nativeFor: fn (*DataTarget, transfer.Format) ?[]const u8) transfer.Operation {
        self.dropPending();
        self.wanted_count = 0;
        const window = self.window orelse return .none;
        const operation = self.negotiated(operations, suggested);
        if (operation == .none) return .none;
        if (self.on_hover) |callback| {
            const scope = window.beginCallback() orelse return .none;
            defer scope.end();
            const value: DataHover = .{ .phase = .over, .point = point, .offer = .{ .formats = self.offered[0..self.offered_count], .operations = operations, .suggested = suggested }, .operation = operation, .local = drag.local(session) != null };
            if (!callback(self.context, window, value)) return .none;
        }
        self.pending = .{ .builder = .init(self.allocator), .point = point, .operation = operation };
        if (drag.local(session)) |source| {
            // Every item of this process's own drag survives.
            var wanted: [transfer.max_formats]transfer.Format = undefined;
            var count: usize = 0;
            for (self.formats) |format| if (self.offers(format)) {
                wanted[count] = format;
                count += 1;
            };
            self.pending.?.local = transfer.materialize(self.allocator, &source.snapshot, wanted[0..count]) catch blk: {
                self.pending.?.failed = true;
                break :blk null;
            };
            return operation;
        }
        for (self.formats) |format| {
            if (!self.offers(format)) continue;
            const name = nativeFor(self, format) orelse continue;
            if (self.wanted_count == self.wanted.len) break;
            self.wanted[self.wanted_count] = .{ .format = format, .native = name };
            self.wanted_count += 1;
        }
        if (self.wanted_count == 0) {
            self.dropPending();
            return .none;
        }
        return operation;
    }
    pub fn wantedFormats(self: *const DataTarget) []const Wanted {
        return self.wanted[0..self.wanted_count];
    }
    /// Native adapter entry: bytes for every wanted format read through
    /// `native_name`; null bytes mark a failed read.
    pub fn receive(self: *DataTarget, native_name: []const u8, bytes: ?[]const u8) void {
        const pending = &(self.pending orelse return);
        const data = bytes orelse {
            pending.failed = true;
            return;
        };
        if (data.len > transfer.max_representation_bytes) {
            pending.failed = true;
            return;
        }
        for (self.wanted[0..self.wanted_count]) |wanted| {
            if (!std.mem.eql(u8, wanted.native, native_name)) continue;
            if (std.mem.eql(u8, wanted.format, transfer.file_list)) {
                // A URI list with no local file is no file list.
                const single = [_]transfer.Item{.{ .representations = &.{.fromBytes(transfer.uri_list, data)} }};
                const paths = transfer.files(self.allocator, .{ .items = &single }) catch {
                    pending.failed = true;
                    continue;
                };
                defer self.allocator.free(paths);
                if (paths.len == 0) continue;
            }
            pending.builder.add(wanted.format, data) catch {
                pending.failed = true;
            };
        }
    }
    /// Native adapter entry: delivers the received data. Returns whether
    /// the drop was taken.
    pub fn complete(self: *DataTarget) bool {
        var pending = self.pending orelse return false;
        self.pending = null;
        defer pending.deinit();
        const window = self.window orelse return false;
        if (pending.failed) return false;
        pending.builder.endItem() catch return false;
        const data: transfer.Data = if (pending.local) |owned| owned.data else .{ .items = pending.builder.items.items };
        if (data.items.len == 0) return false;
        const scope = window.beginCallback() orelse return false;
        defer scope.end();
        return self.on_drop(self.context, window, .{ .point = pending.point, .data = data, .operation = pending.operation, .local = pending.local != null });
    }
    fn dropPending(self: *DataTarget) void {
        if (self.pending) |*pending| pending.deinit();
        self.pending = null;
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
    fn dataAttach(_: *DataTarget, _: *anyopaque) !*anyopaque {
        return error.UnsupportedCapability;
    }
    fn dataDetach(_: *anyopaque) void {}
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
    const DataCallbacks = extern struct {
        hover: *const fn (?*anyopaque, c_int, f64, f64, [*]const u8, usize, c_int, c_int, ?*anyopaque) callconv(.c) c_int,
        drop: *const fn (?*anyopaque, *anyopaque, f64, f64, [*]const u8, usize, c_int, c_int, ?*anyopaque) callconv(.c) c_int,
        received: *const fn (?*anyopaque, [*:0]const u8, ?[*]const u8, c_int) callconv(.c) void,
        complete: *const fn (?*anyopaque) callconv(.c) c_int,
    };
    extern fn zst_target_attach(widget: *anyopaque, owner: *anyopaque, callbacks: *const DataCallbacks) ?*anyopaque;
    extern fn zst_target_detach(target: *anyopaque) void;
    extern fn zst_target_request(record: *anyopaque, name: [*:0]const u8) void;
    const data_callbacks: DataCallbacks = .{ .hover = dataHover, .drop = dataDrop, .received = dataReceived, .complete = dataComplete };
    fn dataAttach(target: *DataTarget, handle: *anyopaque) !*anyopaque {
        return zst_target_attach(handle, target, &data_callbacks) orelse error.AlreadyAttached;
    }
    fn dataDetach(state: *anyopaque) void {
        zst_target_detach(state);
    }
    fn dataOwner(pointer: ?*anyopaque) *DataTarget {
        return @ptrCast(@alignCast(pointer.?));
    }
    /// GTK target names as formats: text targets as text, a URI list also
    /// as a file list.
    fn setOffer(target: *DataTarget, names: []const u8) void {
        target.clearOffer();
        var split = std.mem.splitScalar(u8, names, 0);
        while (split.next()) |name| {
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, "UTF8_STRING") or std.mem.eql(u8, name, "text/plain;charset=utf-8")) {
                target.addOffer(transfer.text);
            } else target.addOffer(name);
            if (std.mem.eql(u8, name, transfer.uri_list)) target.addOffer(transfer.file_list);
        }
    }
    var offered_names: [max_offer_bytes]u8 = undefined;
    var offered_len: usize = 0;
    fn rememberNames(names: []const u8) void {
        offered_len = @min(names.len, offered_names.len);
        @memcpy(offered_names[0..offered_len], names[0..offered_len]);
    }
    fn offeredName(name: []const u8) bool {
        var split = std.mem.splitScalar(u8, offered_names[0..offered_len], 0);
        while (split.next()) |existing| if (std.mem.eql(u8, existing, name)) return true;
        return false;
    }
    /// The GTK target to request for a format: UTF-8 text first.
    fn nativeFor(_: *DataTarget, format: transfer.Format) ?[]const u8 {
        if (std.mem.eql(u8, format, transfer.text)) {
            for ([_][]const u8{ "UTF8_STRING", "text/plain;charset=utf-8", "text/plain" }) |name| if (offeredName(name)) return name;
            return null;
        }
        if (std.mem.eql(u8, format, transfer.file_list)) return transfer.uri_list;
        return if (offeredName(format)) format else null;
    }
    fn operationsOf(actions: c_int) transfer.Operations {
        return .{ .copy = actions & 2 != 0, .move = actions & 4 != 0 };
    }
    fn operationOf(action: c_int) transfer.Operation {
        return if (action & 2 != 0) .copy else if (action & 4 != 0) .move else .none;
    }
    fn actionOf(operation: transfer.Operation) c_int {
        return switch (operation) {
            .none => 0,
            .copy => 2,
            .move => 4,
        };
    }
    fn dataHover(pointer: ?*anyopaque, phase: c_int, x: f64, y: f64, names: [*]const u8, len: usize, actions: c_int, suggested: c_int, session: ?*anyopaque) callconv(.c) c_int {
        const target = dataOwner(pointer);
        const value: Phase = @fromBackingInt(@intCast(phase));
        if (value != .leave) setOffer(target, names[0..len]);
        return actionOf(target.hover(value, .{ .x = @floatCast(x), .y = @floatCast(y) }, operationsOf(actions), operationOf(suggested), session));
    }
    fn dataDrop(pointer: ?*anyopaque, record: *anyopaque, x: f64, y: f64, names: [*]const u8, len: usize, actions: c_int, suggested: c_int, session: ?*anyopaque) callconv(.c) c_int {
        const target = dataOwner(pointer);
        setOffer(target, names[0..len]);
        rememberNames(names[0..len]);
        const operation = target.beginDrop(.{ .x = @floatCast(x), .y = @floatCast(y) }, operationsOf(actions), operationOf(suggested), session, nativeFor);
        if (operation == .none) return 0;
        // One request per GTK target; a URI list serves both list formats.
        const wanted = target.wantedFormats();
        for (wanted, 0..) |item, index| {
            var seen = false;
            for (wanted[0..index]) |earlier| seen = seen or std.mem.eql(u8, earlier.native, item.native);
            if (seen) continue;
            var name: [transfer.max_format_bytes + 1]u8 = undefined;
            @memcpy(name[0..item.native.len], item.native);
            name[item.native.len] = 0;
            zst_target_request(record, name[0..item.native.len :0]);
        }
        return actionOf(operation);
    }
    fn dataReceived(pointer: ?*anyopaque, name: [*:0]const u8, data: ?[*]const u8, len: c_int) callconv(.c) void {
        const target = dataOwner(pointer);
        const bytes: ?[]const u8 = if (len < 0) null else if (data) |value| value[0..@intCast(len)] else "";
        target.receive(std.mem.span(name), bytes);
    }
    fn dataComplete(pointer: ?*anyopaque) callconv(.c) c_int {
        return @intFromBool(dataOwner(pointer).complete());
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
