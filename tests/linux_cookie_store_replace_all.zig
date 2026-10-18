const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const cookies = web.cookies;
const replacements = [_]cookies.Cookie{
    .{ .name = "same", .value = "root", .domain = "replace-cookie.test", .path = "/", .secure = true, .http_only = true, .same_site = .none },
    .{ .name = "same", .value = "nested", .domain = "replace-cookie.test", .path = "/nested", .same_site = .strict },
    .{ .name = "other", .value = "different-domain", .domain = "replace-other.test", .path = "/", .expires = 4102444800 },
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
const State = struct {
    app: *z.App,
    profile: ?*web.Profile,
    writer: ?*web.CookieStore = null,
    reader: ?*web.CookieStore = null,
    bounded: ?*web.CookieStore = null,
    stage: usize = 0,
    completions: usize = 0,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("CookieStore replaceAll stage {d}: {s}\n", .{ self.stage, @errorName(err) });
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
            0, 1, 4, 6 => if (result != .completed) return self.fail(error.MutationDidNotFinish),
            2, 3 => {
                if (result != .cookies or result.cookies.rows.len != 3) return self.fail(error.ReplacementWrongRows);
                var found: u8 = 0;
                for (result.cookies.rows) |row| {
                    if (std.mem.eql(u8, row.name, "old")) return self.fail(error.OldCookieSurvived);
                    for (replacements, 0..) |expected, at| {
                        if (std.mem.eql(u8, row.name, expected.name) and std.mem.eql(u8, row.domain, expected.domain) and std.mem.eql(u8, row.path, expected.path)) {
                            if (!std.mem.eql(u8, row.value, expected.value) or row.secure != expected.secure or row.http_only != expected.http_only or row.same_site != expected.same_site or row.expires != expected.expires) return self.fail(error.ReplacementWrongMetadata);
                            found |= @as(u8, 1) << @intCast(at);
                        }
                    }
                }
                if (found != 7) return self.fail(error.ReplacementMissingCookie);
            },
            5 => if (result != .cookies or result.cookies.rows.len != 1 or !std.mem.eql(u8, result.cookies.rows[0].value, "captured")) return self.fail(error.BorrowedInputWasNotCaptured),
            else => return self.fail(error.UnexpectedCompletion),
        }
        self.stage += 1;
        self.app.post(.{ .context = self, .call = drive }) catch |err| self.fail(err);
    }
    fn drive(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.step() catch |err| self.fail(err);
    }
    fn step(self: *State) !void {
        switch (self.stage) {
            0 => _ = try self.writer.?.set(.{ .name = "old", .value = "removed", .domain = "old-replace.test", .path = "/" }, self.completion()),
            1 => _ = try self.writer.?.replaceAll(&replacements, self.completion()),
            2 => _ = try self.reader.?.listAll(self.completion()),
            3 => {
                const before = try self.writer.?.stats();
                const called = self.completions;
                try std.testing.expectError(error.EmptyCookieReplacement, self.writer.?.replaceAll(&.{}, self.completion()));
                try std.testing.expectError(error.DuplicateCookieIdentity, self.writer.?.replaceAll(&.{ replacements[0], replacements[0] }, self.completion()));
                var invalid = replacements[0];
                invalid.same_site = .none;
                invalid.secure = false;
                try std.testing.expectError(error.InvalidCookie, self.writer.?.replaceAll(&.{invalid}, self.completion()));
                try std.testing.expectError(error.CapacityExceeded, self.bounded.?.replaceAll(&replacements, self.completion()));
                var large: [16384]u8 = @splat('a');
                var first = replacements[0];
                first.value = &large;
                var second = replacements[1];
                second.value = &large;
                try std.testing.expectError(error.CapacityExceeded, self.writer.?.replaceAll(&.{ first, second }, self.completion()));
                const unreadable: [*]const u8 = @ptrFromInt(4096);
                var oversized = replacements[0];
                oversized.value = unreadable[0..cookies.input_byte_capacity];
                try std.testing.expectError(error.CapacityExceeded, self.writer.?.replaceAll(&.{oversized}, self.completion()));
                try std.testing.expectEqualDeep(before, try self.writer.?.stats());
                try std.testing.expectEqual(called, self.completions);
                _ = try self.reader.?.listAll(self.completion());
            },
            4 => {
                // Input is borrowed only until replaceAll returns, not until
                // completion. The actual engine query checks the captured value.
                var value: [8]u8 = "captured".*;
                var rows = [_]cookies.Cookie{.{ .name = "captured", .value = &value, .domain = "captured-replace.test", .path = "/" }};
                _ = try self.writer.?.replaceAll(&rows, self.completion());
                @memset(&value, 'x');
                rows[0] = replacements[0];
            },
            5 => _ = try self.reader.?.listAll(self.completion()),
            6 => {
                _ = try self.writer.?.replaceAll(replacements[0..1], self.completion());
                const profile = self.profile.?;
                self.profile = null;
                try profile.close();
                try std.testing.expectError(error.Closed, self.writer.?.replaceAll(replacements[0..1], self.completion()));
            },
            7 => self.app.quit(),
            else => return error.InvalidStage,
        }
    }
    fn cleanup(self: *State) void {
        for ([_]*?*web.CookieStore{ &self.writer, &self.reader, &self.bounded }) |slot| if (slot.*) |store| {
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
    const path = try std.fmt.allocPrint(allocator, "{s}-replace-all", .{base});
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
    state.writer = try web.CookieStore.create(allocator, app, state.profile.?, .{ .allow_write = true, .allow_replace_all = true });
    state.reader = try web.CookieStore.create(allocator, app, state.profile.?, .{ .allow_read_all = true });
    state.bounded = try web.CookieStore.create(allocator, app, state.profile.?, .{ .allow_replace_all = true, .limits = .{ .max_rows = 1 } });
    const combined = try web.CookieStore.create(allocator, app, state.profile.?, .{ .allow_read_all = true, .allow_write = true, .allow_clear = true });
    defer _ = combined.close() catch unreachable;
    try std.testing.expectError(error.PermissionDenied, combined.replaceAll(&replacements, state.completion()));
    try std.testing.expectError(error.PermissionDenied, state.reader.?.replaceAll(&replacements, state.completion()));
    try std.testing.expectError(error.PermissionDenied, state.bounded.?.listAll(state.completion()));
    try std.testing.expectError(error.PermissionDenied, state.bounded.?.set(replacements[0], state.completion()));
    try std.testing.expectError(error.PermissionDenied, state.bounded.?.clear(.entire_profile_cookies, state.completion()));
    try std.testing.expect((try state.profile.?.stats()).contexts == 0 and app.resourceStats().allocated_records == 0 and web.resourceCounts().states == 0);
    _ = try app.createWindow(.{});
    try app.post(.{ .context = &state, .call = State.drive });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.stage == 7 and state.completions == 7);
    std.debug.print("CookieStore replaceAll native: nonempty single SDK replacement, unrelated old cookie removed, cross-domain/path metadata, caller input reuse after return, accepted Profile seal; no View/Context\n", .{});
}
