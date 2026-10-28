const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const CookieStore = web.CookieStore;
const cookies = web.cookies;

const AllocationCounter = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    fn allocator(self: *AllocationCounter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *AllocationCounter = @ptrCast(@alignCast(ptr));
        self.allocations += 1;
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *AllocationCounter = @ptrCast(@alignCast(ptr));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

extern fn zwk_cookies_counts(*u32, *u32, *usize) void;
extern fn zwk_capture_counts(*u32, *u32, *usize, *usize) void;
extern fn zwk_profile_counts(*u32, *u32, *usize) void;
extern fn g_timeout_add(c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;

const Preparation = struct {
    allocator: std.mem.Allocator,
    main: std.Thread.Id,
    path: []const u8,
    value: ?web.profile_storage.Prepared = null,
    failure: ?anyerror = null,
    fn worker(self: *Preparation) void {
        self.value = web.profile_storage.Prepared.prepare(self.allocator, self.main, self.path, .{}) catch |err| {
            self.failure = err;
            return;
        };
        self.value.?.handoff() catch |err| {
            self.failure = err;
        };
    }
    fn open(self: *Preparation) !void {
        const thread = try std.Thread.spawn(.{}, worker, .{self});
        thread.join();
        if (self.failure) |err| return err;
        try self.value.?.adopt();
    }
};

const State = struct {
    app: *z.App,
    profile: ?*web.Profile,
    store: ?*CookieStore = null,
    reader: ?*CookieStore = null,
    clearer: ?*CookieStore = null,
    bounded: [2]?*CookieStore = .{ null, null },
    budget_completions: usize = 0,
    retained: ?cookies.Batch = null,
    failure: ?anyerror = null,
    stage: usize = 0,
    completions: usize = 0,
    closed: usize = 0,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("CookieStore stage {d}: {s}\n", .{ self.stage, @errorName(err) });
        self.app.quit();
    }
    fn completion(self: *State) cookies.Completion {
        return .{ .context = self, .complete = completed };
    }
    fn completed(ptr: *anyopaque, input: cookies.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var result = input;
        defer if (result == .cookies) result.cookies.deinit();
        self.completions += 1;
        switch (self.stage) {
            0, 2, 4, 6, 7, 9, 11, 13 => if (result != .completed) return self.fail(error.MutationDidNotFinish),
            1 => {
                if (result != .cookies or result.cookies.rows.len != 1) return self.fail(error.ColdQueryWrongRows);
                const row = result.cookies.rows[0];
                if (!std.mem.eql(u8, row.name, "shared") or !std.mem.eql(u8, row.value, "root") or !row.http_only or row.expires == null or row.same_site != .lax) return self.fail(error.ColdQueryWrongCookie);
                self.retained = result.cookies.take() catch |err| return self.fail(err);
            },
            3 => {
                if (result != .cookies or result.cookies.rows.len != 2) return self.fail(error.PathQueryWrongRows);
                var found = false;
                for (result.cookies.rows) |row| if (std.mem.eql(u8, row.path, "/sub") and std.mem.eql(u8, row.value, "nested") and row.same_site == .strict and row.expires == null) {
                    found = true;
                };
                if (!found) return self.fail(error.PathQueryWrongCookie);
            },
            5 => if (result != .cookies or result.cookies.rows.len != 1 or !std.mem.eql(u8, result.cookies.rows[0].path, "/sub")) return self.fail(error.ExactDeleteWrongCookie),
            8 => if (result != .cookies or result.cookies.rows.len != 1 or !std.mem.eql(u8, result.cookies.rows[0].value, "updated")) return self.fail(error.OldSnapshotDeletedUpdatedCookie),
            10, 12 => if (result != .cookies or result.cookies.rows.len != 0 or !result.cookies.isOwned()) return self.fail(error.ClearDidNotFinish),
            else => return self.fail(error.UnexpectedCompletion),
        }
        // The native physical Op remains charged through this callback. A
        // logical slot is free, but a one-slot Store must still return Full.
        if (self.stage <= 10) std.testing.expectError(error.Full, self.store.?.query(.{ .url = "http://127.0.0.1:9443/sub/page" }, self.completion())) catch |err| return self.fail(err);
        if (self.stage == 3) {
            for (self.bounded) |store| {
                _ = store.?.query(.{ .url = "http://127.0.0.1:9443/sub/page" }, .{ .context = self, .complete = budgetComplete }) catch |err| return self.fail(err);
            }
            return;
        }
        self.stage += 1;
        self.app.post(.{ .context = self, .call = drive }) catch |err| self.fail(err);
    }
    fn budgetComplete(ptr: *anyopaque, input: cookies.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var result = input;
        defer if (result == .cookies) result.cookies.deinit();
        if (result != .result_too_large) return self.fail(error.CookieBudgetNotRejected);
        self.budget_completions += 1;
        if (self.budget_completions == 2) {
            self.stage = 4;
            self.app.post(.{ .context = self, .call = drive }) catch |err| self.fail(err);
        }
    }
    fn drive(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.step() catch |err| self.fail(err);
    }
    fn step(self: *State) !void {
        const completion_value = self.completion();
        switch (self.stage) {
            0 => _ = try self.store.?.set(.{ .name = "shared", .value = "root", .domain = "127.0.0.1", .path = "/", .http_only = true, .expires = 4102444800 }, completion_value),
            1 => _ = try self.store.?.query(.{ .url = "http://127.0.0.1:9000/sub/page", .name = "shared", .domain = "127.0.0.1" }, completion_value),
            2 => _ = try self.store.?.set(.{ .name = "shared", .value = "nested", .domain = "127.0.0.1", .path = "/sub", .same_site = .strict }, completion_value),
            3 => _ = try self.store.?.query(.{ .url = "http://127.0.0.1:9443/sub/page", .name = "shared" }, completion_value),
            4 => _ = try self.store.?.deleteExact(.{ .name = "shared", .value = "root", .domain = "127.0.0.1", .path = "/" }, completion_value),
            5 => _ = try self.store.?.query(.{ .url = "http://127.0.0.1:9000/sub/page", .name = "shared" }, completion_value),
            6 => _ = try self.store.?.set(.{ .name = "shared", .value = "updated", .domain = "127.0.0.1", .path = "/sub" }, completion_value),
            7 => _ = try self.store.?.deleteExact(.{ .name = "shared", .value = "nested", .domain = "127.0.0.1", .path = "/sub" }, completion_value),
            8 => _ = try self.store.?.query(.{ .url = "http://127.0.0.1:9000/sub/page", .name = "shared" }, completion_value),
            9 => _ = try self.store.?.deleteExact(.{ .name = "shared", .value = "updated", .domain = "127.0.0.1", .path = "/sub" }, completion_value),
            10 => _ = try self.store.?.query(.{ .url = "http://127.0.0.1:9000/sub/page", .name = "shared" }, completion_value),
            11 => _ = try self.clearer.?.clear(.entire_profile_cookies, completion_value),
            12 => _ = try self.reader.?.query(.{ .url = "http://127.0.0.1:9443/sub/page" }, completion_value),
            13 => {
                _ = try self.store.?.set(.{ .name = "accepted", .value = "survives-seal", .domain = "127.0.0.1", .path = "/" }, completion_value);
                const profile = self.profile.?;
                self.profile = null;
                try profile.close();
                try std.testing.expectError(error.Closed, self.reader.?.query(.{ .url = "http://127.0.0.1/" }, completion_value));
            },
            14 => {
                self.app.quit();
            },
            else => return error.InvalidStage,
        }
    }
    fn ownerClosed(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
    }
    fn cleanup(self: *State) void {
        for (&self.bounded) |*slot| if (slot.*) |store| {
            slot.* = null;
            _ = store.close() catch unreachable;
        };
        for ([_]*?*CookieStore{ &self.store, &self.reader, &self.clearer }) |slot| if (slot.*) |store| {
            slot.* = null;
            _ = store.close() catch unreachable;
        };
        if (self.profile) |profile| {
            self.profile = null;
            profile.close() catch unreachable;
        }
    }
};
fn basic(allocator: std.mem.Allocator, path: []const u8, counter: *AllocationCounter) !cookies.Batch {
    var preparation: Preparation = .{ .allocator = allocator, .main = std.Thread.getCurrentId(), .path = path };
    try preparation.open();
    defer preparation.value.?.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .profile = try web.Profile.create(allocator, app, &preparation.value.?, .{}) };
    defer state.cleanup();
    errdefer if (state.retained) |*batch| batch.deinit();
    state.store = try CookieStore.create(counter.allocator(), app, state.profile.?, .{ .allow_write = true, .limits = .{ .max_pending = 1 }, .on_closed = .{ .context = &state, .notify = State.ownerClosed } });
    state.reader = try CookieStore.create(counter.allocator(), app, state.profile.?, .{});
    state.clearer = try CookieStore.create(counter.allocator(), app, state.profile.?, .{ .allow_clear = true });
    state.bounded[0] = try CookieStore.create(allocator, app, state.profile.?, .{ .limits = .{ .max_rows = 1 } });
    state.bounded[1] = try CookieStore.create(allocator, app, state.profile.?, .{ .limits = .{ .result_bytes = 1 } });
    try std.testing.expect((try state.profile.?.stats()).contexts == 0 and app.resourceStats().allocated_records == 0 and web.resourceCounts().states == 0);
    const value: cookies.Cookie = .{ .name = "denied", .value = "no", .domain = "127.0.0.1", .path = "/" };
    try std.testing.expectError(error.PermissionDenied, state.reader.?.set(value, state.completion()));
    try std.testing.expectError(error.PermissionDenied, state.reader.?.deleteExact(value, state.completion()));
    try std.testing.expectError(error.PermissionDenied, state.store.?.clear(.entire_profile_cookies, state.completion()));
    try std.testing.expectError(error.PermissionDenied, state.clearer.?.set(value, state.completion()));
    for ([_]*CookieStore{ state.reader.?, state.store.?, state.clearer.? }) |store| {
        const before = try store.stats();
        const allocations = counter.allocations;
        try std.testing.expectError(error.PermissionDenied, store.listAll(state.completion()));
        const unreadable: [*]const cookies.Cookie = @ptrFromInt(4096);
        try std.testing.expectError(error.PermissionDenied, store.replaceAll(unreadable[0..1], state.completion()));
        try std.testing.expectEqualDeep(before, try store.stats());
        try std.testing.expectEqual(allocations, counter.allocations);
        try std.testing.expect(state.completions == 0);
    }
    try std.testing.expectError(error.PermissionDenied, state.reader.?.replaceAll(&.{}, state.completion()));
    // This is the host's explicit keepalive, with no Content or WebContext.
    _ = try app.createWindow(.{});
    try app.post(.{ .context = &state, .call = State.drive });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.stage == 14 and state.completions == 14 and state.budget_completions == 2);
    try std.testing.expect(app.resourceStats().allocated_records == 0 and web.resourceCounts().states == 0);
    state.cleanup();
    try std.testing.expect(state.closed == 1);
    const result = try state.retained.?.take();
    state.retained = null;
    return result;
}

/// An explicit test-only App drains native late finish, with no live Store
/// callback. This timer is fixture observation, not a production poll/keepalive.
fn drain(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    const Drain = struct {
        app: *z.App,
        timer: c_uint = 0,
        fn tick(ptr: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            var owners: u32 = 0;
            var ops: u32 = 0;
            var bytes: usize = 0;
            zwk_cookies_counts(&owners, &ops, &bytes);
            if (owners != 0 or ops != 0 or bytes != 0) return 1;
            zwk_profile_counts(&owners, &ops, &bytes);
            var budgets: u32 = 0;
            var captures: u32 = 0;
            var peak: usize = 0;
            zwk_capture_counts(&budgets, &captures, &bytes, &peak);
            if (budgets != 0 or captures != 0) return 1;
            zwk_profile_counts(&owners, &ops, &bytes);
            if (owners != 0 or ops != 0 or bytes != 0 or web.resourceCounts().states != 0 or web.resourceCounts().handlers != 0 or web.resourceCounts().controllers != 0) return 1;
            self.timer = 0;
            self.app.quit();
            return 0;
        }
    };
    var state: Drain = .{ .app = app };
    state.timer = g_timeout_add(10, Drain.tick, &state);
    if (state.timer == 0) return error.TestTimerFailed;
    defer if (state.timer != 0) {
        _ = g_source_remove(state.timer);
    };
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    try std.testing.expect(!watchdog.expired and state.timer == 0);
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var counter: AllocationCounter = .{ .backing = allocator };
    const PreviousOptions = struct {
        allow_write: bool = false,
        allow_clear: bool = false,
        limits: cookies.Limits = .{},
        on_closed: ?CookieStore.ClosedHandler = null,
    };
    try std.testing.expectEqual(@sizeOf(PreviousOptions), @sizeOf(CookieStore.Options));
    std.debug.print("CookieStore explicit grants: Options bytes before={d} after={d}; read-all/replace-all/write/clear stay independent\n", .{ @sizeOf(PreviousOptions), @sizeOf(CookieStore.Options) });
    const base = try zio.getEnvVarOwned(allocator, "ZIGGURAT_PROFILE_TEST_ROOT");
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/cookies-{d}", .{ base, zio.nanoTimestamp() });
    defer allocator.free(path);
    var retained = try basic(allocator, path, &counter);
    defer retained.deinit();
    // This Batch is still valid after Store/Profile/App teardown.
    try std.testing.expectEqualStrings("root", retained.rows[0].value);
    try @import("linux_cookie_store_list_all.zig").run(allocator, path);
    try @import("linux_cookie_store_replace_all.zig").run(allocator, path);
    try @import("linux_cookie_store_delete_key.zig").run(allocator, path);
    try @import("linux_cookie_store_lifetime.zig").run(allocator, path);
    try @import("linux_cookie_store_http.zig").run(allocator, path);
    try @import("linux_view_clear.zig").run(allocator, path);
    try drain(allocator);
    std.debug.print("CookieStore cold native: no View/Context; exact query/path/delete, independent write/clear grants, physical Full, accepted operation survives Profile close, caller Batch after App; native refs=0\n", .{});
}
