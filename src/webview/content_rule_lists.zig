const std = @import("std");
const builtin = @import("builtin");
const rules_format = @import("content_rules.zig");
const webkit = @import("webkit.zig");
const linux = builtin.os.tag == .linux;

/// Content rules compiled for pages to apply: rules that block what pages
/// load and hide parts of them, as an ad or tracker blocker does. One value
/// serves every page that applies it; each holds its own reference.
pub fn Type(comptime z: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        app: *z.App,
        refs: u32 = 1,
        id_bytes: [rules_format.max_id_bytes]u8 = undefined,
        id_len: u8 = 0,
        /// Linux: the engine's compiled list (a WebKitUserContentFilter).
        filter: ?*anyopaque = null,
        /// Windows: the parsed list the page's loads are matched against.
        list: ?*rules_format.List = null,

        pub const CompileOptions = struct {
            /// Linux: an absolute directory where the engine keeps compiled
            /// lists, created when missing. The same rules compiled under the
            /// same id later load from it without compiling again, and
            /// compiling other rules under the id removes the earlier list.
            /// Windows keeps nothing and ignores it.
            store_directory: []const u8 = "",
        };
        pub const NativeFailure = struct { domain: u32, code: i32 };
        pub const Result = union(enum) {
            /// The caller owns this reference: release it once no page needs
            /// to apply the rules any more.
            compiled: *Self,
            /// Rules the engine would not compile. Linux tells no rule index:
            /// the engine reports the list as a whole.
            invalid: rules_format.Failure,
            /// The engine failed otherwise, as storing the list.
            failed: ?NativeFailure,
            out_of_memory,
            /// The App stopped first.
            closed,
        };
        pub const Completion = struct {
            context: *anyopaque,
            /// Called once on the main thread, after compile returned.
            complete: *const fn (*anyopaque, Result) void,
        };

        const Pending = struct {
            allocator: std.mem.Allocator,
            app: *z.App,
            completion: Completion,
            id: [rules_format.max_id_bytes]u8 = undefined,
            id_len: u8 = 0,
            native: ?*anyopaque = null,
            stop_node: z.StopParticipant,
            stop_token: ?z.StopToken = null,
            /// Windows: the parsed result the posted task delivers.
            parsed: ?*rules_format.List = null,
            failure: ?rules_format.Failure = null,
            out_of_memory: bool = false,
            cancelled: bool = false,
        };

        /// A compile in progress. Valid until its completion runs or it is
        /// cancelled.
        pub const Compilation = struct {
            pending: *Pending,
            /// Withdraws the completion: it is not called. The engine may
            /// still finish storing the list.
            pub fn cancel(self: Compilation) void {
                const pending = self.pending;
                pending.app.assertOwner();
                if (linux) {
                    if (pending.native) |native| webkit.zwk_content_cancel(native);
                    if (pending.stop_token) |token| _ = pending.app.cancelStop(token) catch {};
                    pending.allocator.destroy(pending);
                    return;
                }
                // The posted delivery owns the record and drops it.
                pending.cancelled = true;
            }
        };

        /// Compiles rules in the content blocker format under id: 1 to 64
        /// letters, digits, "-", "_" and ".". Rules are borrowed until
        /// return. Main thread only. Linux compiles with the engine's
        /// content filters, off the main thread; Windows parses the rules on
        /// this thread (a list as long as EasyList takes a fraction of a
        /// second) and delivers the result through App.post.
        pub fn compile(allocator: std.mem.Allocator, app: *z.App, list_id: []const u8, rules: []const u8, options: CompileOptions, completion: Completion) !Compilation {
            app.assertOwner();
            const id_text = list_id;
            if (!rules_format.validId(id_text)) return error.InvalidContentRulesId;
            if (!linux and builtin.os.tag != .windows) return error.UnsupportedCapability;
            if (app.phase == .stopping or app.phase == .stopped) return error.Closed;
            if (linux and !std.fs.path.isAbsolute(options.store_directory)) return error.AbsoluteStoreDirectoryRequired;
            const pending = try allocator.create(Pending);
            errdefer allocator.destroy(pending);
            pending.* = .{ .allocator = allocator, .app = app, .completion = completion, .stop_node = .{ .context = pending, .stop = stopped } };
            @memcpy(pending.id[0..id_text.len], id_text);
            pending.id_len = @intCast(id_text.len);
            if (linux) {
                var name_buffer: [rules_format.max_identifier_bytes]u8 = undefined;
                const name = rules_format.identifier(id_text, rules, &name_buffer);
                const directory = try allocator.dupeSentinel(u8, options.store_directory, 0);
                defer allocator.free(directory);
                const id_z = try allocator.dupeSentinel(u8, id_text, 0);
                defer allocator.free(id_z);
                const name_z = try allocator.dupeSentinel(u8, name, 0);
                defer allocator.free(name_z);
                pending.stop_token = try app.registerStop(&pending.stop_node);
                errdefer _ = app.cancelStop(pending.stop_token.?) catch {};
                switch (webkit.zwk_content_compile(directory.ptr, id_z.ptr, name_z.ptr, rules.ptr, rules.len, compiled, pending, &pending.native)) {
                    0 => {},
                    2 => return error.OutOfMemory,
                    3 => return error.ContentRulesStoreUnavailable,
                    else => return error.InvalidContentRulesStore,
                }
                return .{ .pending = pending };
            }
            var failure: rules_format.Failure = undefined;
            if (rules_format.parse(allocator, rules, &failure)) |list| {
                pending.parsed = list;
            } else |err| switch (err) {
                error.OutOfMemory => pending.out_of_memory = true,
                error.InvalidContentRules => pending.failure = failure,
            }
            app.post(.{ .context = pending, .call = deliver }) catch |err| {
                if (pending.parsed) |list| list.deinit();
                return err;
            };
            return .{ .pending = pending };
        }

        fn create(pending: *const Pending) !*Self {
            const self = try pending.allocator.create(Self);
            self.* = .{ .allocator = pending.allocator, .app = pending.app };
            @memcpy(self.id_bytes[0..pending.id_len], pending.id[0..pending.id_len]);
            self.id_len = pending.id_len;
            return self;
        }

        fn deliver(context: *anyopaque) void {
            const pending: *Pending = @ptrCast(@alignCast(context));
            const allocator = pending.allocator;
            defer allocator.destroy(pending);
            if (pending.cancelled) {
                if (pending.parsed) |list| list.deinit();
                return;
            }
            const result: Result = if (pending.parsed) |list| blk: {
                const self = create(pending) catch {
                    list.deinit();
                    break :blk .out_of_memory;
                };
                self.list = list;
                break :blk .{ .compiled = self };
            } else if (pending.failure) |failure| .{ .invalid = failure } else .out_of_memory;
            pending.completion.complete(pending.completion.context, result);
        }

        fn compiled(context: ?*anyopaque, filter: ?*anyopaque, invalid: c_int, domain: u32, code: i32) callconv(.c) void {
            const pending: *Pending = @ptrCast(@alignCast(context.?));
            const app = pending.app;
            const scope = app.beginNativeCallback();
            defer scope.end();
            pending.native = null;
            if (pending.stop_token) |token| _ = app.cancelStop(token) catch {};
            pending.stop_token = null;
            const completion = pending.completion;
            const result: Result = if (filter) |native| blk: {
                const self = create(pending) catch {
                    webkit.zwk_content_filter_unref(native);
                    break :blk .out_of_memory;
                };
                self.filter = native;
                break :blk .{ .compiled = self };
            } else if (invalid != 0) .{ .invalid = .{ .reason = .rejected_by_engine } } else .{ .failed = if (domain != 0) .{ .domain = domain, .code = code } else null };
            pending.allocator.destroy(pending);
            completion.complete(completion.context, result);
        }

        fn stopped(context: *anyopaque) !void {
            const pending: *Pending = @ptrCast(@alignCast(context));
            pending.stop_token = null;
            if (linux) if (pending.native) |native| webkit.zwk_content_cancel(native);
            const completion = pending.completion;
            pending.allocator.destroy(pending);
            completion.complete(completion.context, .closed);
        }

        /// The id the rules were compiled under.
        pub fn id(self: *const Self) []const u8 {
            return self.id_bytes[0..self.id_len];
        }

        /// Takes another reference. Main thread only.
        pub fn retain(self: *Self) *Self {
            self.app.assertOwner();
            self.refs += 1;
            return self;
        }

        /// Drops a reference; the last frees the compiled list. Pages that
        /// apply the rules hold references of their own. Main thread only.
        pub fn release(self: *Self) void {
            self.app.assertOwner();
            self.refs -= 1;
            if (self.refs != 0) return;
            if (linux) if (self.filter) |filter| webkit.zwk_content_filter_unref(filter);
            if (self.list) |list| list.deinit();
            self.allocator.destroy(self);
        }

        /// Whether any of the lists hides elements (Windows), so a page
        /// needs the hiding script.
        pub fn hides(self: *const Self) bool {
            return if (self.list) |list| list.hides() else false;
        }
    };
}

/// Compile operations the engine has not finished, cancelled ones included.
pub fn nativeCompileCount() u32 {
    return if (linux) webkit.zwk_content_compile_count() else 0;
}
