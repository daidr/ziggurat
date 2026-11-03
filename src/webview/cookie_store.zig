const std = @import("std");
const os = @import("builtin").os.tag;
/// The engine-backed store: WebKitGTK on Linux, WKHTTPCookieStore on macOS.
const native_store = os == .linux or os == .macos;
const cookies = @import("cookies.zig");

/// Independent, explicitly Profile-owned cookie operations. There is no
/// hidden page, Context, Window, worker, timer or application keepalive.
pub fn Type(comptime z: type, comptime Profile: type) type {
    return struct {
        const Self = @This();
        pub const CloseResult = enum { closed, deferred };
        pub const ClosedHandler = struct { context: *anyopaque, notify: *const fn (*anyopaque) void };
        pub const Options = struct {
            /// Authorizes set/delete, including HttpOnly cookies. URL-origin
            /// permission is not implied; this grants the whole Profile store.
            allow_write: bool = false,
            /// Independent of allow_write; only cookie data is cleared.
            allow_clear: bool = false,
            /// Independent whole-Profile read grant; query remains URL-scoped.
            allow_read_all: bool = false,
            /// Replaces the whole Profile cookie set. No other grant implies it.
            allow_replace_all: bool = false,
            limits: cookies.Limits = .{},
            /// Zig owner final release, not native operation/quiescence proof.
            on_closed: ?ClosedHandler = null,
        };
        pub const Operation = struct {
            store: *Self,
            token: u64,
            /// The Store must outlive every use of this token. Cancellation
            /// completes logical ownership once, not a rollback of a mutation.
            pub fn cancel(self: Operation) !bool {
                return self.store.cancel(self.token);
            }
        };
        pub const Stats = struct {
            owned_bytes: usize,
            /// Peak requested project storage reservation, including a result
            /// candidate whose caller allocation may subsequently fail.
            peak_reserved_bytes: usize,
            logical_pending: usize,
            physical_pending: u32,
            accepting: bool,
        };
        allocator: std.mem.Allocator,
        app: *z.App,
        native: ?*anyopaque,
        options: Options,
        book: cookies.Book = .{},
        stop_node: z.StopParticipant,
        stop_token: ?z.StopToken = null,
        phase: enum { open, stopped, closing, closed } = .open,
        pins: usize = 0,
        busy: bool = false,
        peak_bytes: usize = 0,

        /// App outlives the Zig Store and its explicit close. Native operations
        /// may finish later, with only C/GObject state. Profile may close first.
        /// Windows rejects this independent API before touching Profile/input.
        pub fn create(allocator: std.mem.Allocator, app: *z.App, profile: *Profile, options: Options) !*Self {
            if (!native_store) return error.UnsupportedCapability;
            if (std.Thread.getCurrentId() != app.owner) return error.WrongThread;
            const app_scope = app.beginCallback() orelse return error.Closed;
            defer app_scope.end();
            try options.limits.validate();
            if (options.limits.bytes <= @sizeOf(Self) + zwk_cookies_owner_size()) return error.CapacityExceeded;
            // Retain both the manager and C-only Profile state before the first
            // caller allocation can close/free the public Profile pointer.
            var lease = try profile.retainForApp(app);
            var native: ?*anyopaque = null;
            const status = zwk_cookies_create(lease.native.?, &.{ .bytes = options.limits.bytes - @sizeOf(Self), .pending = options.limits.max_pending, .rows = options.limits.max_rows }, &native);
            try lease.release();
            try nativeError(status);
            errdefer _ = zwk_cookies_close(native.?);
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .app = app, .native = native, .options = options, .stop_node = .{ .context = self, .stop = stop }, .peak_bytes = @sizeOf(Self) + zwk_cookies_owner_size(), .busy = true };
            try self.checkIngress();
            self.stop_token = try app.registerStop(&self.stop_node);
            errdefer {
                if (self.stop_token) |token| _ = app.cancelStop(token) catch unreachable;
            }
            try nativeError(zwk_cookies_bind(native.?, self, completed));
            // No foreign call follows publication.
            self.busy = false;
            return self;
        }
        pub fn query(self: *Self, filter: cookies.Filter, completion: cookies.Completion) !Operation {
            try self.checkOwner();
            if (self.busy) return error.Busy;
            try self.checkIngress();
            try cookies.validateFilter(filter);
            return self.submit(.{
                .kind = 0,
                .filter_flags = @as(u32, if (filter.name != null) 1 else 0) | @as(u32, if (filter.domain != null) 2 else 0) | @as(u32, if (filter.path != null) 4 else 0),
                .url = slice(filter.url),
                .name = slice(filter.name orelse ""),
                .domain = slice(filter.domain orelse ""),
                .path = slice(filter.path orelse ""),
            }, completion);
        }
        pub fn set(self: *Self, cookie: cookies.Cookie, completion: cookies.Completion) !Operation {
            try self.checkOwner();
            if (self.busy) return error.Busy;
            try self.checkIngress();
            try cookies.validateCookie(cookie);
            if (!self.options.allow_write) return error.PermissionDenied;
            return self.submit(.{ .kind = 1, .name = slice(cookie.name), .value = slice(cookie.value), .domain = slice(cookie.domain), .path = slice(cookie.path), .expires = cookie.expires orelse 0, .flags = @as(u32, if (cookie.secure) 1 else 0) | @as(u32, if (cookie.http_only) 2 else 0) | @as(u32, if (cookie.expires != null) 4 else 0), .same_site = @backingInt(cookie.same_site) }, completion);
        }
        /// Uses an observed cookie's native identity and expected value. This
        /// is not an atomic compare-delete or unconditional key-only deletion.
        pub fn deleteExact(self: *Self, cookie: cookies.Cookie, completion: cookies.Completion) !Operation {
            try self.checkOwner();
            if (self.busy) return error.Busy;
            try self.checkIngress();
            try cookies.validateDelete(cookie);
            if (!self.options.allow_write) return error.PermissionDenied;
            return self.submit(.{ .kind = 2, .name = slice(cookie.name), .value = slice(cookie.value), .domain = slice(cookie.domain), .path = slice(cookie.path) }, completion);
        }
        /// Expires a native name/domain/path identity without reading its value.
        /// Domain matching follows the engine; leading dots and exact paths are
        /// retained. Completion is not a visibility or persistence barrier.
        pub fn deleteKey(self: *Self, key: cookies.Key, completion: cookies.Completion) !Operation {
            if (!native_store) return error.UnsupportedCapability;
            try self.checkOwner();
            if (self.busy) return error.Busy;
            try self.checkIngress();
            if (!self.options.allow_write) return error.PermissionDenied;
            try cookies.validateKey(key);
            return self.submit(.{ .kind = 6, .name = slice(key.name), .domain = slice(key.domain), .path = slice(key.path), .same_site = 0 }, completion);
        }
        pub fn clear(self: *Self, _: cookies.ClearScope, completion: cookies.Completion) !Operation {
            try self.checkOwner();
            if (self.busy) return error.Busy;
            try self.checkIngress();
            if (!self.options.allow_clear) return error.PermissionDenied;
            return self.submit(.{ .kind = 3 }, completion);
        }
        /// Explicitly authorized whole-Profile read, without URL eligibility.
        /// Optional native API pair: older engines reject before acceptance.
        pub fn listAll(self: *Self, completion: cookies.Completion) !Operation {
            if (!native_store) return error.UnsupportedCapability;
            try self.checkOwner();
            if (self.busy) return error.Busy;
            try self.checkIngress();
            if (!self.options.allow_read_all) return error.PermissionDenied;
            return self.submit(.{ .kind = 4 }, completion);
        }
        /// Copies a nonempty input before one native replacement. Failures
        /// before acceptance preserve the store; native completion/cancellation
        /// has no transactional rollback or persistence guarantee.
        pub fn replaceAll(self: *Self, input: []const cookies.Cookie, completion: cookies.Completion) !Operation {
            if (!native_store) return error.UnsupportedCapability;
            try self.checkOwner();
            if (self.busy) return error.Busy;
            try self.checkIngress();
            if (!self.options.allow_replace_all) return error.PermissionDenied;
            _ = try cookies.measureReplacement(input, self.options.limits.max_rows, @sizeOf(NativeRow) + @sizeOf(NativeList));
            try cookies.validateReplacement(input, self.options.limits.max_rows);
            var captured: [cookies.row_capacity]NativeRow = undefined;
            for (input, captured[0..input.len]) |row, *out| out.* = .{ .name = slice(row.name), .value = slice(row.value), .domain = slice(row.domain), .path = slice(row.path), .expires = row.expires orelse 0, .flags = @as(u32, if (row.secure) 1 else 0) | @as(u32, if (row.http_only) 2 else 0) | @as(u32, if (row.expires != null) 4 else 0), .same_site = @backingInt(row.same_site) };
            return self.submitCandidate(.{ .replacement = captured[0..input.len] }, completion);
        }
        pub fn stats(self: *Self) !Stats {
            try self.checkOwner();
            if (self.busy) return error.Busy;
            var native: NativeStats = undefined;
            if (native_store) try nativeError(zwk_cookies_stats(self.native orelse return error.Closed, &native)) else return error.UnsupportedCapability;
            var count: usize = 0;
            for (self.book.slots) |slot| if (slot != null) {
                count += 1;
            };
            return .{ .owned_bytes = native.bytes + @sizeOf(Self), .peak_reserved_bytes = @max(self.peak_bytes, native.peak_bytes + @sizeOf(Self)), .logical_pending = count, .physical_pending = native.pending, .accepting = self.phase == .open and native.accepting != 0 and self.app.phase != .stopping and self.app.phase != .stopped };
        }
        /// Completion/on_closed may reenter close. While pinned this is deferred;
        /// a taken Stop node returns StopInProgress without withdrawing anything.
        pub fn close(self: *Self) !CloseResult {
            try self.checkOwner();
            if (self.phase == .closed) return .closed;
            const scope = self.beginTeardown();
            defer scope.end();
            if (self.phase == .closing) return .deferred;
            if (self.stop_token) |token| _ = try self.app.cancelStop(token);
            self.stop_token = null;
            self.phase = .closing;
            self.finishLogical(.closed);
            return if (self.pins == 1) .closed else .deferred;
        }
        fn submit(self: *Self, request: NativeRequest, completion: cookies.Completion) !Operation {
            return self.submitCandidate(.{ .single = request }, completion);
        }
        const Candidate = union(enum) { single: NativeRequest, replacement: []const NativeRow };
        fn submitCandidate(self: *Self, candidate: Candidate, completion: cookies.Completion) !Operation {
            if (!native_store) return error.UnsupportedCapability;
            try self.checkOwner();
            if (self.busy) return error.Busy;
            const scope = self.beginBusiness() orelse return error.Closed;
            defer scope.end();
            self.busy = true;
            defer self.busy = false;
            try self.checkIngress();
            const is_query = switch (candidate) {
                .single => |request| request.kind == 0 or request.kind == 4,
                .replacement => false,
            };
            const token = try self.book.reserve(completion, self.options.limits.max_pending, is_query);
            // Every native error precedes acceptance and invokes no callback.
            const status = switch (candidate) {
                .single => |request| zwk_cookies_submit(self.native.?, token, &request),
                .replacement => |rows| zwk_cookies_replace(self.native.?, token, rows.ptr, rows.len),
            };
            if (status != 0) {
                _ = self.book.take(token);
                try nativeError(status);
            }
            return .{ .store = self, .token = token };
        }
        fn cancel(self: *Self, token: u64) !bool {
            try self.checkOwner();
            const scope = self.beginTeardown();
            defer scope.end();
            const slot = self.book.take(token) orelse return false;
            if (native_store) try nativeError(zwk_cookies_cancel(self.native.?, token));
            slot.completion.complete(slot.completion.context, .cancelled);
            return true;
        }
        fn finishLogical(self: *Self, result: cookies.Result) void {
            if (native_store) _ = zwk_cookies_seal(self.native.?);
            const batch = self.book.takeAll();
            if (native_store) _ = zwk_cookies_cancel_all(self.native.?);
            for (batch) |slot| if (slot) |value| value.completion.complete(value.completion.context, result);
        }
        fn stop(context: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            const scope = self.beginTeardown();
            defer scope.end();
            self.stop_token = null;
            if (self.phase == .open) self.phase = .stopped;
            self.finishLogical(.stopped);
        }
        fn completed(context: ?*anyopaque, token: u64, status: c_int, domain: u32, code: i32, rows: ?[*]const NativeRow, count: usize) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const native_scope = self.app.beginNativeCallback();
            defer native_scope.end();
            const scope = self.beginTeardown();
            defer scope.end();
            // Keep the logical slot until copying has survived every foreign
            // allocator callback. A reentrant close takes it and completes once.
            if (!self.book.contains(token)) return;
            var result: cookies.Result = switch (status) {
                0 => .completed,
                3 => .out_of_memory,
                8 => .result_too_large,
                9 => .cancelled,
                else => .{ .native_failure = if (domain != 0) .{ .domain = domain, .code = code } else null },
            };
            const prior_busy = self.busy;
            self.busy = true;
            if (status == 0) {
                var query_result = false;
                for (self.book.slots) |slot| if (slot) |value| if (value.token == token) {
                    query_result = value.query;
                    break;
                };
                if (query_result) result = self.copyResult(rows, count) catch |err| switch (err) {
                    error.OutOfMemory => .out_of_memory,
                    error.CookieResultTooLarge, error.CapacityExceeded => .result_too_large,
                    else => .invalid_result,
                };
            }
            self.busy = prior_busy;
            const slot = self.book.take(token) orelse {
                if (result == .cookies) result.cookies.deinit();
                return;
            };
            slot.completion.complete(slot.completion.context, result);
        }
        fn copyResult(self: *Self, rows: ?[*]const NativeRow, count: usize) !cookies.Result {
            if (count > self.options.limits.max_rows or (count != 0 and rows == null)) return error.CookieResultTooLarge;
            var values: [cookies.row_capacity]cookies.Cookie = undefined;
            for (values[0..count], 0..) |*out, i| {
                const row = rows.?[i];
                if (row.same_site > 2 or row.flags > 7) return error.InvalidCookieResult;
                out.* = .{ .name = row.name.bytes(), .value = row.value.bytes(), .domain = row.domain.bytes(), .path = row.path.bytes(), .expires = if (row.flags & 4 != 0) row.expires else null, .secure = row.flags & 1 != 0, .http_only = row.flags & 2 != 0, .same_site = @fromBackingInt(@intCast(row.same_site)) };
            }
            const bytes = try cookies.Batch.measure(values[0..count], self.options.limits);
            var native: NativeStats = undefined;
            if (native_store) try nativeError(zwk_cookies_stats(self.native.?, &native)) else return error.UnsupportedCapability;
            const base = @sizeOf(Self) + native.bytes;
            if (base > self.options.limits.bytes or bytes > self.options.limits.bytes - base) return error.CapacityExceeded;
            self.peak_bytes = @max(self.peak_bytes, base + bytes);
            return .{ .cookies = try cookies.Batch.init(self.allocator, values[0..count], self.options.limits) };
        }
        fn checkOwner(self: *Self) !void {
            if (std.Thread.getCurrentId() != self.app.owner) return error.WrongThread;
        }
        fn checkIngress(self: *Self) !void {
            if (self.phase != .open or self.app.phase == .stopping or self.app.phase == .stopped) return error.Closed;
            if (native_store) try nativeError(zwk_cookies_check(self.native orelse return error.Closed)) else return error.UnsupportedCapability;
        }
        fn beginBusiness(self: *Self) ?Scope {
            if (self.phase != .open) return null;
            const app_scope = self.app.beginCallback() orelse return null;
            self.pins += 1;
            return .{ .store = self, .app_scope = app_scope };
        }
        fn beginTeardown(self: *Self) Scope {
            const app_scope = self.app.beginTeardownCallback();
            self.pins += 1;
            return .{ .store = self, .app_scope = app_scope };
        }
        const Scope = struct {
            store: *Self,
            app_scope: z.AppCallbackScope,
            fn end(self: Scope) void {
                const app = self.app_scope.app;
                self.store.release();
                (z.AppCallbackScope{ .app = app }).end();
            }
        };
        fn release(self: *Self) void {
            std.debug.assert(self.pins != 0);
            self.pins -= 1;
            if (self.pins != 0 or self.phase != .closing) return;
            self.phase = .closed;
            self.busy = true;
            const native = self.native;
            self.native = null;
            const allocator = self.allocator;
            const handler = self.options.on_closed;
            self.options.on_closed = null;
            if (native_store) {
                if (native) |pointer| _ = zwk_cookies_close(pointer);
            }
            allocator.destroy(self);
            if (handler) |closed| closed.notify(closed.context);
        }
    };
}

pub const NativeCounts = struct { stores: u32 = 0, operations: u32 = 0, bytes: usize = 0 };
pub fn nativeCounts() NativeCounts {
    var result: NativeCounts = .{};
    if (native_store) zwk_cookies_counts(&result.stores, &result.operations, &result.bytes);
    return result;
}
const Slice = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
    fn bytes(self: Slice) []const u8 {
        return if (self.len == 0) "" else self.ptr.?[0..self.len];
    }
};
fn slice(value: []const u8) Slice {
    return .{ .ptr = value.ptr, .len = value.len };
}
const NativeRow = extern struct { name: Slice, value: Slice, domain: Slice, path: Slice, expires: i64, flags: u32, same_site: u32 };
/// GLib's transfer-none GList node layout, embedded in the C Op allocation.
const NativeList = extern struct { data: ?*anyopaque, next: ?*anyopaque, prev: ?*anyopaque };
const NativeRequest = extern struct { kind: u32, filter_flags: u32 = 0, url: Slice = .{}, name: Slice = .{}, value: Slice = .{}, domain: Slice = .{}, path: Slice = .{}, expires: i64 = 0, flags: u32 = 0, same_site: u32 = 1 };
const NativeOptions = extern struct { bytes: usize, pending: u32, rows: u32 };
const NativeStats = extern struct { bytes: usize, peak_bytes: usize, pending: u32, accepting: c_int };
fn nativeError(status: c_int) !void {
    return switch (status) {
        0 => {},
        1 => error.Closed,
        2 => error.Full,
        3 => error.OutOfMemory,
        4 => error.InvalidCookie,
        5 => error.WrongThread,
        8 => error.CapacityExceeded,
        10 => error.UnsupportedCapability,
        else => error.CookieNativeFailed,
    };
}
extern fn zwk_cookies_owner_size() usize;
extern fn zwk_cookies_create(*anyopaque, *const NativeOptions, *?*anyopaque) c_int;
extern fn zwk_cookies_bind(*anyopaque, *anyopaque, *const fn (?*anyopaque, u64, c_int, u32, i32, ?[*]const NativeRow, usize) callconv(.c) void) c_int;
extern fn zwk_cookies_check(*anyopaque) c_int;
extern fn zwk_cookies_submit(*anyopaque, u64, *const NativeRequest) c_int;
extern fn zwk_cookies_replace(*anyopaque, u64, [*]const NativeRow, usize) c_int;
extern fn zwk_cookies_cancel(*anyopaque, u64) c_int;
extern fn zwk_cookies_cancel_all(*anyopaque) c_int;
extern fn zwk_cookies_seal(*anyopaque) c_int;
extern fn zwk_cookies_close(*anyopaque) c_int;
extern fn zwk_cookies_stats(*anyopaque, *NativeStats) c_int;
extern fn zwk_cookies_counts(*u32, *u32, *usize) void;
