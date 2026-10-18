const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const cookies = web.cookies;

const host_root: cookies.Cookie = .{ .name = "same", .value = "original", .domain = "identity-cookie.test", .path = "/", .secure = true, .http_only = true, .same_site = .none, .expires = 4102444800 };
const host_nested: cookies.Cookie = .{ .name = "same", .value = "nested", .domain = "identity-cookie.test", .path = "/nested", .same_site = .strict };
const domain_root: cookies.Cookie = .{ .name = "same", .value = "domain", .domain = ".identity-cookie.test", .path = "/", .http_only = true };
const other_root: cookies.Cookie = .{ .name = "same", .value = "other", .domain = "identity-other.test", .path = "/" };
const secure_prefix: cookies.Cookie = .{ .name = "__Secure-token", .value = "secure", .domain = "identity-cookie.test", .path = "/", .secure = true, .http_only = true };
const host_prefix: cookies.Cookie = .{ .name = "__Host-token", .value = "host", .domain = "identity-cookie.test", .path = "/", .secure = true, .http_only = true };
const empty_value: cookies.Cookie = .{ .name = "empty", .value = "", .domain = "identity-cookie.test", .path = "/" };
const updated_nested: cookies.Cookie = .{ .name = "same", .value = "updated", .domain = "identity-cookie.test", .path = "/nested", .secure = true, .http_only = true, .same_site = .none };
const Query = struct { filter: cookies.Filter, expected: []const cookies.Cookie };
const Action = union(enum) { set: cookies.Cookie, delete: cookies.Key, query: Query, captured, seal };
const actions = [_]Action{
    .{ .set = host_root },
    .{ .set = host_nested },
    .{ .set = domain_root },
    .{ .set = other_root },
    .{ .set = secure_prefix },
    .{ .set = host_prefix },
    .{ .set = empty_value },
    .{ .query = .{ .filter = .{ .url = "https://identity-cookie.test/nested/page", .name = "same" }, .expected = &.{ host_root, host_nested, domain_root } } },
    // Domain lookup is the engine's case-insensitive identity lookup. The dot
    // remains meaningful: this expires only the host-only root, not domain_root.
    .captured,
    .{ .query = .{ .filter = .{ .url = "https://identity-cookie.test/nested/page", .name = "same" }, .expected = &.{ host_nested, domain_root } } },
    .{ .query = .{ .filter = .{ .url = "https://child.identity-cookie.test/", .name = "same" }, .expected = &.{domain_root} } },
    .{ .query = .{ .filter = .{ .url = "https://identity-other.test/", .name = "same" }, .expected = &.{other_root} } },
    .{ .delete = .{ .name = "same", .domain = ".identity-cookie.test", .path = "/" } },
    .{ .query = .{ .filter = .{ .url = "https://identity-cookie.test/nested/page", .name = "same" }, .expected = &.{host_nested} } },
    .{ .set = updated_nested },
    .{ .query = .{ .filter = .{ .url = "https://identity-cookie.test/nested/page", .name = "same" }, .expected = &.{updated_nested} } },
    // No stale or current value is supplied to this deletion.
    .{ .delete = .{ .name = "same", .domain = "identity-cookie.test", .path = "/nested" } },
    .{ .query = .{ .filter = .{ .url = "https://identity-cookie.test/nested/page", .name = "same" }, .expected = &.{} } },
    .{ .delete = .{ .name = "same", .domain = "identity-other.test" } },
    .{ .query = .{ .filter = .{ .url = "https://identity-other.test/", .name = "same" }, .expected = &.{} } },
    .{ .query = .{ .filter = .{ .url = "https://identity-cookie.test/", .name = "__Secure-token" }, .expected = &.{secure_prefix} } },
    .{ .delete = .{ .name = "__Secure-token", .domain = "identity-cookie.test" } },
    .{ .query = .{ .filter = .{ .url = "https://identity-cookie.test/", .name = "__Secure-token" }, .expected = &.{} } },
    .{ .query = .{ .filter = .{ .url = "https://identity-cookie.test/", .name = "__Host-token" }, .expected = &.{host_prefix} } },
    .{ .delete = .{ .name = "__Host-token", .domain = "identity-cookie.test" } },
    .{ .query = .{ .filter = .{ .url = "https://identity-cookie.test/", .name = "__Host-token" }, .expected = &.{} } },
    .{ .delete = .{ .name = "absent", .domain = "identity-cookie.test", .path = "/missing" } },
    .{ .query = .{ .filter = .{ .url = "https://identity-cookie.test/missing", .name = "absent" }, .expected = &.{} } },
    .{ .delete = .{ .name = "empty", .domain = "identity-cookie.test" } },
    .{ .query = .{ .filter = .{ .url = "https://identity-cookie.test/", .name = "empty" }, .expected = &.{} } },
    .seal,
};
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
};
const Counter = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    fn allocator(self: *Counter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.allocations += 1;
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        self.backing.rawFree(bytes, alignment, ra);
    }
};
const State = struct {
    app: *z.App,
    profile: ?*web.Profile,
    writer: ?*web.CookieStore = null,
    reader: ?*web.CookieStore = null,
    stage: usize = 0,
    completions: usize = 0,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("CookieStore deleteKey stage {d}: {s}\n", .{ self.stage, @errorName(err) });
        self.app.quit();
    }
    fn completion(self: *State) cookies.Completion {
        return .{ .context = self, .complete = completed };
    }
    fn checkRows(result: cookies.Result, expected: []const cookies.Cookie) !void {
        if (result != .cookies or result.cookies.rows.len != expected.len) return error.IdentityWrongRowCount;
        for (expected) |wanted| {
            var found = false;
            for (result.cookies.rows) |row| {
                if (!std.mem.eql(u8, row.name, wanted.name) or !std.mem.eql(u8, row.domain, wanted.domain) or !std.mem.eql(u8, row.path, wanted.path)) continue;
                if (!std.mem.eql(u8, row.value, wanted.value) or row.secure != wanted.secure or row.http_only != wanted.http_only or row.same_site != wanted.same_site or row.expires != wanted.expires) return error.IdentityWrongMetadata;
                found = true;
            }
            if (!found) return error.IdentityMissingCookie;
        }
    }
    fn completed(ptr: *anyopaque, input: cookies.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var result = input;
        defer if (result == .cookies) result.cookies.deinit();
        self.completions += 1;
        switch (actions[self.stage]) {
            .query => |query| checkRows(result, query.expected) catch |err| return self.fail(err),
            else => if (result != .completed) return self.fail(error.IdentityMutationDidNotFinish),
        }
        if (actions[self.stage] == .delete or actions[self.stage] == .captured) {
            // A logical completion does not release its GTask physical slot.
            std.testing.expectError(error.Full, self.writer.?.deleteKey(.{ .name = "absent", .domain = "identity-cookie.test" }, self.completion())) catch |err| return self.fail(err);
        }
        self.stage += 1;
        self.app.post(.{ .context = self, .call = drive }) catch |err| self.fail(err);
    }
    fn drive(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.step() catch |err| self.fail(err);
    }
    fn step(self: *State) !void {
        if (self.stage == actions.len) {
            self.app.quit();
            return;
        }
        switch (actions[self.stage]) {
            .set => |cookie| _ = try self.writer.?.set(cookie, self.completion()),
            .delete => |key| _ = try self.writer.?.deleteKey(key, self.completion()),
            .query => |query| _ = try self.reader.?.query(query.filter, self.completion()),
            .captured => {
                var name = "same".*;
                var domain = "IDENTITY-cookie.test".*;
                var path = "/".*;
                _ = try self.writer.?.deleteKey(.{ .name = &name, .domain = &domain, .path = &path }, self.completion());
                @memset(&name, 'x');
                @memset(&domain, 'x');
                @memset(&path, 'x');
            },
            .seal => {
                _ = try self.writer.?.deleteKey(.{ .name = "absent", .domain = "identity-cookie.test" }, self.completion());
                const profile = self.profile.?;
                self.profile = null;
                try profile.close();
                const unreadable: [*]const u8 = @ptrFromInt(4096);
                try std.testing.expectError(error.Closed, self.writer.?.deleteKey(.{ .name = unreadable[0..1], .domain = unreadable[0..1], .path = unreadable[0..1] }, self.completion()));
            },
        }
    }
    fn cleanup(self: *State) void {
        for ([_]*?*web.CookieStore{ &self.writer, &self.reader }) |slot| if (slot.*) |store| {
            slot.* = null;
            _ = store.close() catch unreachable;
        };
        if (self.profile) |profile| {
            self.profile = null;
            profile.close() catch unreachable;
        }
    }
};
pub fn run(allocator: std.mem.Allocator, base: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}-delete-key", .{base});
    defer allocator.free(path);
    var preparation: Preparation = .{ .allocator = allocator, .main = std.Thread.getCurrentId(), .path = path };
    const thread = try std.Thread.spawn(.{}, Preparation.worker, .{&preparation});
    thread.join();
    if (preparation.failure) |err| return err;
    try preparation.value.?.adopt();
    defer preparation.value.?.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .profile = try web.Profile.create(allocator, app, &preparation.value.?, .{}) };
    defer state.cleanup();
    var counter: Counter = .{ .backing = allocator };
    state.writer = try web.CookieStore.create(counter.allocator(), app, state.profile.?, .{ .allow_write = true, .limits = .{ .max_pending = 1 } });
    state.reader = try web.CookieStore.create(counter.allocator(), app, state.profile.?, .{});
    const unreadable: [*]const u8 = @ptrFromInt(4096);
    const unreadable_key: cookies.Key = .{ .name = unreadable[0..1], .domain = unreadable[0..1], .path = unreadable[0..1] };
    for ([_]web.CookieStore.Options{ .{}, .{ .allow_read_all = true }, .{ .allow_clear = true }, .{ .allow_replace_all = true }, .{ .allow_read_all = true, .allow_clear = true, .allow_replace_all = true } }) |options| {
        const denied = try web.CookieStore.create(counter.allocator(), app, state.profile.?, options);
        defer _ = denied.close() catch unreachable;
        const before = try denied.stats();
        const native = web.cookieStoreNativeCounts();
        const allocations = counter.allocations;
        try std.testing.expectError(error.PermissionDenied, denied.deleteKey(unreadable_key, state.completion()));
        try std.testing.expectEqualDeep(before, try denied.stats());
        try std.testing.expectEqualDeep(native, web.cookieStoreNativeCounts());
        try std.testing.expectEqual(allocations, counter.allocations);
        try std.testing.expectEqual(@as(usize, 0), state.completions);
    }
    const before = try state.writer.?.stats();
    const allocations = counter.allocations;
    for ([_]cookies.Key{ .{ .name = "", .domain = "identity-cookie.test" }, .{ .name = "bad;name", .domain = "identity-cookie.test" }, .{ .name = "same", .domain = "identity-cookie.test", .path = "relative" }, .{ .name = unreadable[0..513], .domain = "identity-cookie.test" } }) |key| try std.testing.expectError(error.InvalidCookie, state.writer.?.deleteKey(key, state.completion()));
    try std.testing.expectEqualDeep(before, try state.writer.?.stats());
    try std.testing.expectEqual(allocations, counter.allocations);
    try std.testing.expectEqual(@as(usize, 0), state.completions);
    try std.testing.expect((try state.profile.?.stats()).contexts == 0 and app.resourceStats().allocated_records == 0 and web.resourceCounts().states == 0);
    _ = try app.createWindow(.{});
    try app.post(.{ .context = &state, .call = State.drive });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.stage == actions.len and state.completions == actions.len);
    std.debug.print("CookieStore deleteKey native: one expired add; changed/empty/absent values, exact name/path, host-only/domain-dot, native case lookup, Secure/HttpOnly/prefixes, captured inputs, explicit write grant, Profile seal; no View/Context\n", .{});
}
