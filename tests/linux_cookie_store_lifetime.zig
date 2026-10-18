const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
const Mode = enum { cancel, stop, close, allocation_close, allocation_oom, creation_close, final_free, taken_stop, creation_oom, stop_full };
const Read = enum { query, list_all, replace_all, delete_key };
const Fixture = struct {
    allocator: std.mem.Allocator,
    main: std.Thread.Id,
    path: []const u8,
    prepared: ?web.profile_storage.Prepared = null,
    failure: ?anyerror = null,
    fn worker(self: *Fixture) void {
        self.prepared = web.profile_storage.Prepared.prepare(self.allocator, self.main, self.path, .{}) catch |err| {
            self.failure = err;
            return;
        };
        self.prepared.?.handoff() catch |err| {
            self.failure = err;
        };
    }
    fn open(self: *Fixture) !void {
        const thread = try std.Thread.spawn(.{}, worker, .{self});
        thread.join();
        if (self.failure) |err| return err;
        try self.prepared.?.adopt();
    }
};
const Gate = struct {
    backing: std.mem.Allocator,
    state: ?*State = null,
    armed: bool = false,
    acted: bool = false,
    store_address: ?*anyopaque = null,
    fn allocator(self: *Gate) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Gate = @ptrCast(@alignCast(ptr));
        if (self.armed and !self.acted) {
            self.acted = true;
            const state = self.state.?;
            switch (state.mode) {
                .allocation_oom => return null,
                .allocation_close => {
                    const result = state.store.?.close() catch |err| {
                        state.fail(err);
                        return null;
                    };
                    if (result != .deferred) state.fail(error.CopyDidNotPinStore);
                },
                .creation_close => {
                    const profile = state.profile.?;
                    state.profile = null;
                    profile.close() catch |err| state.fail(err);
                },
                else => {},
            }
        }
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Gate = @ptrCast(@alignCast(ptr));
        if (self.armed and !self.acted and self.state.?.mode == .final_free and self.store_address == @as(*anyopaque, @ptrCast(bytes.ptr))) {
            self.acted = true;
            const state = self.state.?;
            _ = state.window.destroy() catch |err| {
                state.fail(err);
                return;
            };
            if (state.window_closed != 0) state.fail(error.WindowClosedInsideStoreFree);
        }
        self.backing.rawFree(bytes, alignment, ra);
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    profile: ?*web.Profile,
    store: ?*web.CookieStore = null,
    window: z.Window = undefined,
    mode: Mode,
    read: Read,
    gate: *Gate,
    failure: ?anyerror = null,
    completions: usize = 0,
    closed: usize = 0,
    window_closed: usize = 0,
    taken_checked: bool = false,
    peer: z.StopParticipant = undefined,
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("Cookie lifetime {s}/{s}: {s}\n", .{ @tagName(self.read), @tagName(self.mode), @errorName(err) });
        self.app.quit();
    }
    fn completion(self: *State) web.cookies.Completion {
        return .{ .context = self, .complete = complete };
    }
    fn complete(ptr: *anyopaque, input: web.cookies.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var result = input;
        defer if (result == .cookies) result.cookies.deinit();
        self.completions += 1;
        const okay = switch (self.mode) {
            .cancel => result == .cancelled,
            .stop, .taken_stop => result == .stopped,
            .close, .allocation_close => result == .closed,
            .allocation_oom => result == .out_of_memory,
            else => false,
        };
        if (!okay or self.completions != 1) return self.fail(error.WrongLogicalCompletion);
        if (self.mode == .close) {
            const value = self.store.?.close() catch |err| return self.fail(err);
            if (value != .deferred or self.closed != 0) return self.fail(error.CloseDidNotDefer);
        }
        if (self.mode == .allocation_close or self.mode == .allocation_oom) self.app.quit();
    }
    fn storeClosed(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        self.store = null;
    }
    fn windowClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.window_closed += 1;
    }
    fn peerStop(ptr: *anyopaque) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        try std.testing.expectError(error.StopInProgress, self.store.?.close());
        self.taken_checked = true;
    }
    fn drive(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.step() catch |err| self.fail(err);
    }
    fn step(self: *State) !void {
        if (self.mode == .creation_oom or self.mode == .stop_full) {
            const before = web.cookieStoreNativeCounts();
            const expected = if (self.mode == .creation_oom) error.OutOfMemory else error.Full;
            try std.testing.expectError(expected, web.CookieStore.create(if (self.mode == .creation_oom) std.testing.failing_allocator else self.allocator, self.app, self.profile.?, .{ .on_closed = .{ .context = self, .notify = storeClosed } }));
            try std.testing.expectEqualDeep(before, web.cookieStoreNativeCounts());
            try std.testing.expect(self.closed == 0);
            self.app.quit();
            return;
        }
        if (self.mode == .creation_close) {
            self.gate.armed = true;
            try std.testing.expectError(error.Closed, web.CookieStore.create(self.gate.allocator(), self.app, self.profile.?, .{ .on_closed = .{ .context = self, .notify = storeClosed } }));
            try std.testing.expect(self.gate.acted and self.profile == null);
            try std.testing.expect(self.closed == 0);
            self.app.quit();
            return;
        }
        if (self.mode == .final_free) {
            self.gate.armed = true;
            _ = try self.store.?.close();
            try std.testing.expect(self.closed == 1 and self.gate.acted and self.window_closed == 0);
            self.app.quit();
            return;
        }
        const operation = try self.readOperation();
        switch (self.mode) {
            .cancel => {
                try std.testing.expect(try operation.cancel());
                try std.testing.expect(!try operation.cancel());
                try std.testing.expectError(error.Full, self.readOperation());
                const stats = try self.store.?.stats();
                try std.testing.expect(stats.logical_pending == 0 and stats.physical_pending == 1);
                _ = try self.store.?.close();
                self.app.quit();
            },
            .stop, .taken_stop => self.app.quit(),
            .close => {
                _ = try self.store.?.close();
                try std.testing.expect(self.closed == 1 and self.store == null);
                self.app.quit();
            },
            .allocation_close, .allocation_oom => self.gate.armed = true,
            else => unreachable,
        }
    }
    fn readOperation(self: *State) !web.CookieStore.Operation {
        return switch (self.read) {
            .query => self.store.?.query(.{ .url = "https://cold-cookie.test/" }, self.completion()),
            .list_all => self.store.?.listAll(self.completion()),
            .replace_all => self.store.?.replaceAll(&.{.{ .name = "replacement", .value = "accepted", .domain = "lifetime-replace.test", .path = "/", .http_only = true }}, self.completion()),
            .delete_key => self.store.?.deleteKey(.{ .name = "absent", .domain = "lifetime-delete.test" }, self.completion()),
        };
    }
};
fn runCase(allocator: std.mem.Allocator, path: []const u8, mode: Mode, read: Read) !void {
    var fixture: Fixture = .{ .allocator = allocator, .main = std.Thread.getCurrentId(), .path = path };
    try fixture.open();
    defer fixture.prepared.?.close() catch unreachable;
    const app = try z.App.initWithOptions(allocator, .{ .stop_capacity = if (mode == .stop_full) 1 else 256 });
    defer app.deinit();
    var gate: Gate = .{ .backing = allocator };
    var state: State = .{ .allocator = allocator, .app = app, .profile = try web.Profile.create(allocator, app, &fixture.prepared.?, .{}), .mode = mode, .read = read, .gate = &gate };
    gate.state = &state;
    defer if (state.store) |store| {
        _ = store.close() catch unreachable;
    };
    defer if (state.profile) |profile| profile.close() catch unreachable;
    state.window = try app.createWindow(.{ .on_closed = .{ .context = &state, .notify = State.windowClosed } });
    if (mode != .creation_close and mode != .creation_oom and mode != .stop_full) {
        state.store = try web.CookieStore.create(gate.allocator(), app, state.profile.?, .{ .allow_write = read == .delete_key, .allow_read_all = read == .list_all, .allow_replace_all = read == .replace_all, .limits = .{ .max_pending = 1 }, .on_closed = .{ .context = &state, .notify = State.storeClosed } });
        gate.store_address = state.store;
    }
    if (mode == .taken_stop) {
        state.peer = .{ .context = &state, .stop = State.peerStop };
        _ = try app.registerStop(&state.peer);
    }
    try app.post(.{ .context = &state, .call = State.drive });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.window_closed == 1);
    const expected: usize = if (mode == .creation_close or mode == .final_free or mode == .creation_oom or mode == .stop_full) 0 else 1;
    try std.testing.expectEqual(expected, state.completions);
    if (mode == .taken_stop) try std.testing.expect(state.taken_checked);
    if (mode == .allocation_close or mode == .allocation_oom or mode == .creation_close) try std.testing.expect(gate.acted);
    if (state.store) |store| {
        try std.testing.expectError(error.Closed, state.readOperation());
        _ = try store.close();
        try std.testing.expect(state.store == null);
    }
    if (mode != .creation_close and mode != .creation_oom and mode != .stop_full) try std.testing.expectEqual(@as(usize, 1), state.closed);
    if (state.profile) |profile| {
        state.profile = null;
        try profile.close();
    }
}
pub fn run(allocator: std.mem.Allocator, base: []const u8) !void {
    for (std.meta.tags(Read)) |read| {
        for (std.meta.tags(Mode)) |mode| {
            if (read != .query and (mode == .creation_close or mode == .final_free or mode == .creation_oom or mode == .stop_full)) continue;
            if ((read == .replace_all or read == .delete_key) and (mode == .allocation_close or mode == .allocation_oom)) continue;
            const path = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ base, @tagName(read), @tagName(mode) });
            defer allocator.free(path);
            try runCase(allocator, path, mode, read);
        }
    }
    std.debug.print("CookieStore lifetime: query/listAll/replaceAll/deleteKey cancel/physical Full, Stop/taken Stop, recursive close; reads result allocator close/OOM; construction Profile close, final free Window pin\n", .{});
}
