const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const cookies = web.cookies;

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
    bounded: [2]?*web.CookieStore = .{ null, null },
    stage: usize = 0,
    completions: usize = 0,
    budget_completions: usize = 0,
    retained: ?cookies.Batch = null,
    failure: ?anyerror = null,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("CookieStore listAll stage {d}: {s}\n", .{ self.stage, @errorName(err) });
        self.app.quit();
    }
    fn completion(self: *State) cookies.Completion {
        return .{ .context = self, .complete = completed };
    }
    fn inspect(rows: []const cookies.Cookie) !void {
        try std.testing.expectEqual(@as(usize, 3), rows.len);
        var found: u8 = 0;
        for (rows) |row| {
            if (std.mem.eql(u8, row.domain, "cookie-list.test") and std.mem.eql(u8, row.name, "same") and std.mem.eql(u8, row.path, "/")) {
                try std.testing.expectEqualStrings("root", row.value);
                try std.testing.expect(row.http_only and row.secure and row.same_site == .none and row.expires == null);
                found |= 1;
            } else if (std.mem.eql(u8, row.domain, "cookie-list.test") and std.mem.eql(u8, row.name, "same") and std.mem.eql(u8, row.path, "/hidden")) {
                try std.testing.expectEqualStrings("nested", row.value);
                try std.testing.expect(!row.http_only and !row.secure and row.same_site == .strict and row.expires == null);
                found |= 2;
            } else if (std.mem.eql(u8, row.domain, "other-cookie.test") and std.mem.eql(u8, row.name, "other")) {
                try std.testing.expectEqualStrings("unrelated", row.value);
                try std.testing.expect(row.secure and row.expires != null and row.expires.? == 4102444800);
                found |= 4;
            } else return error.UnexpectedCookieIdentity;
        }
        try std.testing.expectEqual(@as(u8, 7), found);
    }
    fn completed(ptr: *anyopaque, input: cookies.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var result = input;
        defer if (result == .cookies) result.cookies.deinit();
        self.completions += 1;
        switch (self.stage) {
            0, 4 => if (result != .cookies or !result.cookies.isOwned() or result.cookies.rows.len != 0) return self.fail(error.ExpectedEmptyBatch),
            1, 2, 3 => if (result != .completed) return self.fail(error.MutationDidNotFinish),
            5, 7 => {
                if (result != .cookies) return self.fail(error.ExpectedFullBatch);
                inspect(result.cookies.rows) catch |err| return self.fail(err);
                if (self.stage == 7) self.retained = result.cookies.take() catch |err| return self.fail(err);
            },
            else => return self.fail(error.UnexpectedCompletion),
        }
        self.stage += 1;
        self.app.post(.{ .context = self, .call = drive }) catch |err| self.fail(err);
    }
    fn budgetCompleted(ptr: *anyopaque, input: cookies.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var result = input;
        defer if (result == .cookies) result.cookies.deinit();
        if (result != .result_too_large) return self.fail(error.EnumerationWasTruncatedOrOverBudget);
        self.budget_completions += 1;
        if (self.budget_completions == 2) {
            self.stage = 7;
            self.app.post(.{ .context = self, .call = drive }) catch |err| self.fail(err);
        }
    }
    fn drive(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.step() catch |err| self.fail(err);
    }
    fn step(self: *State) !void {
        switch (self.stage) {
            0 => _ = try self.reader.?.listAll(self.completion()),
            1 => _ = try self.writer.?.set(.{ .name = "same", .value = "root", .domain = "cookie-list.test", .path = "/", .secure = true, .http_only = true, .same_site = .none }, self.completion()),
            2 => _ = try self.writer.?.set(.{ .name = "same", .value = "nested", .domain = "cookie-list.test", .path = "/hidden", .same_site = .strict }, self.completion()),
            3 => _ = try self.writer.?.set(.{ .name = "other", .value = "unrelated", .domain = "other-cookie.test", .path = "/", .secure = true, .expires = 4102444800 }, self.completion()),
            4 => _ = try self.reader.?.query(.{ .url = "http://cookie-list.test/" }, self.completion()),
            5 => _ = try self.reader.?.listAll(self.completion()),
            6 => for (self.bounded) |store| {
                _ = try store.?.listAll(.{ .context = self, .complete = budgetCompleted });
            },
            7 => {
                _ = try self.reader.?.listAll(self.completion());
                const profile = self.profile.?;
                self.profile = null;
                try profile.close();
                try std.testing.expectError(error.Closed, self.writer.?.listAll(self.completion()));
            },
            8 => self.app.quit(),
            else => return error.InvalidStage,
        }
    }
    fn cleanup(self: *State) void {
        for (&self.bounded) |*slot| if (slot.*) |store| {
            slot.* = null;
            _ = store.close() catch unreachable;
        };
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
fn enumerate(allocator: std.mem.Allocator, path: []const u8) !cookies.Batch {
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
    errdefer if (state.retained) |*batch| batch.deinit();
    state.writer = try web.CookieStore.create(allocator, app, state.profile.?, .{ .allow_write = true });
    state.reader = try web.CookieStore.create(allocator, app, state.profile.?, .{ .allow_read_all = true });
    state.bounded[0] = try web.CookieStore.create(allocator, app, state.profile.?, .{ .allow_read_all = true, .limits = .{ .max_rows = 2 } });
    state.bounded[1] = try web.CookieStore.create(allocator, app, state.profile.?, .{ .allow_read_all = true, .limits = .{ .result_bytes = 1 } });
    try std.testing.expect((try state.profile.?.stats()).contexts == 0 and app.resourceStats().allocated_records == 0 and web.resourceCounts().states == 0);
    // The fixture owns its explicit keepalive; enumeration creates no page.
    _ = try app.createWindow(.{});
    try app.post(.{ .context = &state, .call = State.drive });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.stage == 8 and state.completions == 7 and state.budget_completions == 2);
    try std.testing.expect(app.resourceStats().allocated_records == 0 and web.resourceCounts().states == 0);
    const result = try state.retained.?.take();
    state.retained = null;
    return result;
}
pub fn run(allocator: std.mem.Allocator, base: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}-list-all", .{base});
    defer allocator.free(path);
    var retained = try enumerate(allocator, path);
    defer retained.deinit();
    try State.inspect(retained.rows);
    std.debug.print("CookieStore listAll native: empty/full owning batches, three cookies across two domains and paths, Secure/HttpOnly/SameSite/expiry, no URL eligibility filter, independent row/byte limits without truncation, accepted Profile seal, Batch after App; no View/Context\n", .{});
}
