const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Prepared = web.profile_storage.Prepared;
extern fn zwk_profile_counts(*u32, *u32, *usize) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_object_unref(*anyopaque) void;

const Preparation = struct {
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    path: []const u8,
    prepared: ?Prepared = null,
    failure: ?anyerror = null,
    fn worker(self: *Preparation) void {
        self.prepared = Prepared.prepare(self.allocator, self.main_thread, self.path, .{}) catch |err| {
            self.failure = err;
            return;
        };
        self.prepared.?.handoff() catch |err| {
            self.failure = err;
        };
    }
    fn open(self: *Preparation) !void {
        const thread = try std.Thread.spawn(.{}, worker, .{self});
        thread.join();
        if (self.failure) |err| return err;
        try self.prepared.?.adopt();
    }
};

const Stop = struct {
    owner: ?*web.Profile = null,
    calls: usize = 0,
    taken_blocked: bool = false,
    fn call(ptr: *anyopaque) !void {
        const self: *Stop = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.owner) |owner| {
            try std.testing.expectError(error.StopInProgress, owner.close());
            self.taken_blocked = true;
        }
    }
};

fn empty() !void {
    var profiles: u32 = 0;
    var contexts: u32 = 0;
    var bytes: usize = 0;
    zwk_profile_counts(&profiles, &contexts, &bytes);
    try std.testing.expect(profiles == 0 and contexts == 0 and bytes == 0);
}

fn failures(allocator: std.mem.Allocator, path: []const u8) !void {
    var prepared: Preparation = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .path = path };
    try prepared.open();
    defer prepared.prepared.?.close() catch unreachable;
    const app = try z.App.initWithOptions(allocator, .{ .stop_capacity = 2 });
    defer app.deinit();
    _ = try app.createWindow(.{});
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, web.Profile.create(failing.allocator(), app, &prepared.prepared.?, .{}));
    try std.testing.expect((try prepared.prepared.?.stats()).active_leases == 0 and app.resourceStats().stop_participants == 0);
    try empty();
    var one: Stop = .{};
    var two: Stop = .{};
    var first: z.StopParticipant = .{ .context = &one, .stop = Stop.call };
    var second: z.StopParticipant = .{ .context = &two, .stop = Stop.call };
    const t1 = try app.registerStop(&first);
    const t2 = try app.registerStop(&second);
    try std.testing.expectError(error.Full, web.Profile.create(allocator, app, &prepared.prepared.?, .{}));
    try std.testing.expect((try prepared.prepared.?.stats()).active_leases == 0 and app.resourceStats().stop_participants == 2);
    try empty();
    try std.testing.expect(try app.cancelStop(t1));
    try std.testing.expect(try app.cancelStop(t2));
    const owner = try web.Profile.create(allocator, app, &prepared.prepared.?, .{});
    defer owner.close() catch unreachable;
    defer one.owner = null;
    var foreign_app: z.App = undefined;
    try std.testing.expectError(error.ForeignApp, owner.retainForApp(&foreign_app));
    failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.ProfileStorageAlreadyClaimed, web.Profile.create(failing.allocator(), app, &prepared.prepared.?, .{}));
    try std.testing.expect(failing.alloc_index == 0);
    one.owner = owner;
    _ = try app.registerStop(&first);
    try app.post(.{ .context = app, .call = struct {
        fn call(ptr: *anyopaque) void {
            const value: *z.App = @ptrCast(@alignCast(ptr));
            value.quit();
        }
    }.call });
    try app.run();
    try std.testing.expect(one.calls == 1 and two.calls == 0 and one.taken_blocked);
    try std.testing.expect(!(try owner.stats()).accepting and app.resourceStats().allocated_records == 0 and app.resourceStats().stop_participants == 0);
    try std.testing.expectError(error.Closed, owner.retainForApp(app));
}

pub const Reentry = struct {
    backing: std.mem.Allocator,
    app: *z.App,
    owner_slot: ?*?*web.Profile = null,
    window: ?z.Window = null,
    target: ?*web.Profile = null,
    view: ?*web.View = null,
    scratch: ?[*]u8 = null,
    action: enum { idle, quit_on_alloc, close_on_alloc, close_on_free, close_after_config, close_last_scratch } = .idle,
    acted: bool = false,
    busy: bool = false,
    withdrawn: bool = false,
    callback_error: ?anyerror = null,
    closed: bool = false,
    deferred: bool = false,
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    pub fn allocator(self: *Reentry) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Reentry = @ptrCast(@alignCast(ptr));
        if (!self.acted) switch (self.action) {
            .quit_on_alloc => {
                self.acted = true;
                self.app.quit();
            },
            .close_on_alloc => {
                self.closeOwner();
            },
            .close_after_config => if (self.view.?.config != null) self.closeOwner(),
            else => {},
        };
        const result = self.backing.rawAlloc(len, alignment, address);
        if (self.action == .close_last_scratch and self.scratch == null and self.view.?.config != null) self.scratch = result;
        return result;
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
        const self: *Reentry = @ptrCast(@alignCast(ptr));
        return self.backing.rawResize(bytes, alignment, len, address);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const self: *Reentry = @ptrCast(@alignCast(ptr));
        return self.backing.rawRemap(bytes, alignment, len, address);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Reentry = @ptrCast(@alignCast(ptr));
        if (self.action == .close_last_scratch and !self.acted and self.scratch == bytes.ptr) {
            self.withdrawn = self.view.?.native != null;
            self.closeOwner();
        }
        if (self.action == .close_on_free and !self.acted) {
            self.acted = true;
            const owner = self.target.?;
            self.withdrawn = owner.base.native == null;
            if (owner.close()) |_| {} else |err| {
                self.busy = err == error.Busy;
            }
            const result = self.window.?.destroy() catch |err| blk: {
                self.callback_error = err;
                break :blk z.CloseResult.in_progress;
            };
            self.deferred = result == .deferred and !self.closed;
        }
        self.backing.rawFree(bytes, alignment, address);
    }
    fn closeOwner(self: *Reentry) void {
        self.acted = true;
        const slot = self.owner_slot.?;
        const owner = slot.*.?;
        slot.* = null;
        owner.close() catch |err| {
            self.callback_error = err;
        };
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *Reentry = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
};

fn creationQuit(allocator: std.mem.Allocator, path: []const u8) !void {
    var prepared: Preparation = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .path = path };
    try prepared.open();
    defer prepared.prepared.?.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var gate: Reentry = .{ .backing = allocator, .app = app, .action = .quit_on_alloc };
    try std.testing.expectError(error.Closed, web.Profile.create(gate.allocator(), app, &prepared.prepared.?, .{}));
    try std.testing.expect(gate.acted and (try prepared.prepared.?.stats()).active_leases == 0);
    try std.testing.expect(app.resourceStats().stop_participants == 0);
    try app.finishShutdown();
    try empty();
}

fn closeReentry(allocator: std.mem.Allocator, path: []const u8) !void {
    var prepared: Preparation = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .path = path };
    try prepared.open();
    defer prepared.prepared.?.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var gate: Reentry = .{ .backing = allocator, .app = app };
    gate.window = try app.createWindow(.{ .on_closed = .{ .context = &gate, .notify = Reentry.onClosed } });
    gate.target = try web.Profile.create(gate.allocator(), app, &prepared.prepared.?, .{});
    gate.action = .close_on_free;
    try gate.target.?.close();
    gate.target = null;
    if (gate.callback_error) |err| return err;
    try std.testing.expect(gate.acted and gate.withdrawn and gate.busy and gate.deferred and !gate.closed);
    try app.dispatch();
    try std.testing.expect(gate.closed and app.resourceStats().allocated_records == 0);
    try empty();
}

fn lateNative(allocator: std.mem.Allocator, path: []const u8) !void {
    var prepared: Preparation = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .path = path };
    try prepared.open();
    const app = try z.App.init(allocator);
    const owner = try web.Profile.create(allocator, app, &prepared.prepared.?, .{});
    // Exercise exactly the C-only lease/token used by a View configuration.
    // The retained native Context is released after both public owners die.
    var lease = try owner.retainForApp(app);
    var context = try lease.context();
    try context.admit();
    const retained = g_object_ref(try context.webContext());
    try owner.close();
    try context.close();
    try lease.release();
    try prepared.prepared.?.close();
    app.deinit();
    var profiles: u32 = 0;
    var contexts: u32 = 0;
    var bytes: usize = 0;
    zwk_profile_counts(&profiles, &contexts, &bytes);
    try std.testing.expect(profiles == 1 and contexts == 1 and bytes > 0);
    g_object_unref(retained);
    try empty();
}

const Attachment = enum { window, region, session };
fn attachRevocation(allocator: std.mem.Allocator, path: []const u8, attachment: Attachment, final_free: bool) !void {
    var prepared: Preparation = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .path = path };
    try prepared.open();
    defer prepared.prepared.?.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var owner: ?*web.Profile = try web.Profile.create(allocator, app, &prepared.prepared.?, .{});
    defer if (owner) |value| value.close() catch unreachable;
    var gate: Reentry = .{ .backing = allocator, .app = app, .owner_slot = &owner, .action = if (final_free) .close_last_scratch else .close_after_config };
    var view = web.View.init(gate.allocator(), &gate, struct {
        fn event(_: *anyopaque, _: *web.View, _: web.Event) void {}
    }.event);
    var session = web.PageSession.init(gate.allocator(), &gate, struct {
        fn event(_: *anyopaque, _: *web.View, _: web.Event) void {}
    }.event);
    var composition: ?*z.composition.Owner = null;
    defer if (composition) |value| {
        value.detach() catch unreachable;
        value.close() catch unreachable;
    };
    gate.view = if (attachment == .session) &session.page else &view;
    const options: web.Options = .{ .html = "<title>Revoked candidate</title>", .storage = .profile, .profile = owner };
    const result = switch (attachment) {
        .window => view.attach(window, options),
        .region => blk: {
            composition = try z.composition.Owner.create(allocator, window, .{});
            const region = try composition.?.reserve(.{ .bounds = .{ .x = 0, .y = 0, .width = 80, .height = 60 } });
            break :blk view.attachRegion(region, options);
        },
        .session => session.open(app, .{ .page = options }),
    };
    if (result) {
        if (attachment == .session) _ = try session.close();
        if (composition) |value| try value.detach();
        _ = try window.destroy();
        std.debug.print("Profile {s} candidate accepted after {s}\n", .{ @tagName(attachment), if (final_free) "native-created final scratch free" else "native scratch allocation" });
        return error.RevokedProfileAttachmentAccepted;
    } else |err| try std.testing.expectEqual(error.Closed, err);
    if (gate.callback_error) |err| return err;
    if (attachment == .session) {
        _ = try session.close();
        try std.testing.expect(session.phase == .closed and session.page.native == null and session.page.config == null);
    } else try std.testing.expect(view.native == null and view.config == null and view.window == null and view.attachment_phase == .detached);
    try std.testing.expect(gate.acted and owner == null);
    if (final_free) try std.testing.expect(gate.withdrawn);
}

pub fn run(allocator: std.mem.Allocator, path: []const u8) !void {
    try failures(allocator, path);
    try empty();
    const create_path = try std.fmt.allocPrint(allocator, "{s}-creation", .{path});
    defer allocator.free(create_path);
    try creationQuit(allocator, create_path);
    const close_path = try std.fmt.allocPrint(allocator, "{s}-close", .{path});
    defer allocator.free(close_path);
    try closeReentry(allocator, close_path);
    const late_path = try std.fmt.allocPrint(allocator, "{s}-late", .{path});
    defer allocator.free(late_path);
    try lateNative(allocator, late_path);
    var rejected: usize = 0;
    for (std.enums.values(Attachment)) |attachment| {
        for ([_]bool{ false, true }) |final_free| {
            const candidate_path = try std.fmt.allocPrint(allocator, "{s}-attach-{s}-{s}", .{ path, @tagName(attachment), if (final_free) "final" else "allocate" });
            defer allocator.free(candidate_path);
            attachRevocation(allocator, candidate_path, attachment, final_free) catch |err| {
                rejected += 1;
                std.debug.print("Profile candidate {s}/{s}: {s}\n", .{ @tagName(attachment), if (final_free) "final-free" else "allocate", @errorName(err) });
            };
        }
    }
    if (rejected != 0) return error.ProfileRevocationChecksFailed;
    std.debug.print("Profile owner: OOM/Stop Full rollback, one-writer before allocation, ForeignApp, taken Stop blocks close, Stop seals, construction quit, withdrawn final free pins on_closed, C-only last ref after App/Prepared release; native refs=0\n", .{});
}

fn attachAllocation(allocator: std.mem.Allocator, app: *z.App, owner: *web.Profile, origin: []const u8, extension: []const u8) !void {
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var marker: u8 = 0;
    var view = web.View.init(allocator, &marker, struct {
        fn event(_: *anyopaque, _: *web.View, _: web.Event) void {
            @panic("closed allocation-test View received callback");
        }
    }.event);
    view.attach(window, .{
        .html = "",
        .storage = .profile,
        .profile = owner,
        .user_agent = "Ziggurat explicit profile allocation fixture",
        .remote = .{ .url = origin, .origins = &.{.{ .origin = origin, .ipc = true }}, .credentials = .profile, .allow_insecure_loopback = true },
        .request_policy_extension = .{ .directory = extension },
    }) catch |err| {
        try std.testing.expect(view.native == null and view.config == null and view.window == null and view.attachment_phase == .detached);
        return err;
    };
    _ = try window.destroy();
    try std.testing.expect(view.native == null and view.config == null and view.window == null);
}

pub fn allocations(allocator: std.mem.Allocator, path: []const u8, origin: []const u8, extension: []const u8) !void {
    var prepared: Preparation = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .path = path };
    try prepared.open();
    defer prepared.prepared.?.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    const owner = try web.Profile.create(allocator, app, &prepared.prepared.?, .{ .contexts = 16 });
    defer owner.close() catch unreachable;
    try std.testing.checkAllAllocationFailures(allocator, attachAllocation, .{ app, owner, origin, extension });
    try std.testing.expect((try owner.stats()).leases == 0);
    try app.post(.{ .context = app, .call = struct {
        fn call(ptr: *anyopaque) void {
            const value: *z.App = @ptrCast(@alignCast(ptr));
            value.quit();
        }
    }.call });
    try app.run();
    std.debug.print("Profile View: every host allocation failure rolls back C lease/Context/native/config and caller ownership\n", .{});
}
