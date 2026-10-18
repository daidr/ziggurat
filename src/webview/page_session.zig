const std = @import("std");
const z = @import("ziggurat");

/// Private type factory keeps the page engine's implementation hooks in its
/// own module. Page storage, configuration and request books are never copied.
pub fn Type(comptime Page: type, comptime Hooks: type) type {
    return struct {
        const Self = @This();
        pub const CloseResult = enum { closed, deferred };
        pub const Phase = enum { fresh, opening, open, closing, closed };
        pub const AttachmentPhase = enum { detached, attaching, attached, detaching };
        pub const ClosedHandler = struct {
            context: *anyopaque,
            /// Final notification: the handler may release this Session.
            notify: *const fn (*anyopaque, *Self) void,
        };
        pub const OpenOptions = struct {
            page: Hooks.Options,
            /// Physical client pixels, applied before controller creation.
            initial_size: PixelSize = .{ .width = 800, .height = 600 },
            on_closed: ?ClosedHandler = null,
        };
        pub const PixelSize = struct { width: u32, height: u32 };

        page: Page,
        app: ?*z.App = null,
        phase: Phase = .fresh,
        opened: bool = false,
        pins: usize = 0,
        finishing: bool = false,
        page_closed: bool = false,
        native_closed: bool = false,
        on_closed: ?ClosedHandler = null,
        stop_node: z.StopParticipant = undefined,
        stop_token: ?z.StopToken = null,
        native_host: ?*anyopaque = null,
        native_bridge: ?*anyopaque = null,
        last_hresult: i32 = 0,
        region: ?z.composition.Region = null,
        provider_window: ?z.Window = null,
        host_parent: ?*anyopaque = null,
        attachment_phase: AttachmentPhase = .detached,
        attachment_epoch: u64 = 0,
        parent_loss: ?i32 = null,
        last_size: PixelSize = .{ .width = 800, .height = 600 },

        pub fn init(allocator: std.mem.Allocator, context: *anyopaque, on_event: *const fn (*anyopaque, *Page, Hooks.Event) void) Self {
            return .{ .page = Page.init(allocator, context, on_event) };
        }

        /// The address becomes stable before open and remains stable through
        /// on_closed. A failed open may still need close if native cleanup fails.
        pub fn open(self: *Self, app: *z.App, options: OpenOptions) !void {
            app.assertOwner();
            if (self.phase != .fresh) return error.AlreadyOpened;
            const app_scope = app.beginCallback() orelse return error.Closed;
            defer app_scope.end();
            self.app = app;
            self.phase = .opening;
            self.pins += 1;
            defer self.release();
            self.on_closed = options.on_closed;
            self.stop_node = .{ .context = self, .stop = stop };
            self.stop_token = app.registerStop(&self.stop_node) catch |err| {
                self.phase = .closing;
                return err;
            };
            self.last_size = options.initial_size;
            Hooks.open(self, options.page, options.initial_size) catch |err| {
                self.phase = .closing;
                return err;
            };
            if (!self.accepts()) {
                self.phase = .closing;
                return error.Closed;
            }
            self.opened = true;
            self.phase = .open;
        }

        /// Parking preserves the document generation and all accepted requests.
        /// A new attachment waits until the old provider's detach has completed.
        pub fn park(self: *Self) !void {
            const scope = self.beginCallback() orelse return error.Closed;
            defer scope.end();
            const region = self.region orelse return;
            if (self.attachment_phase == .attaching) return error.Busy;
            if (self.attachment_phase == .detaching) return error.Busy;
            const region_scope = region.beginCallback() orelse return error.Closed;
            defer region_scope.end();
            try Hooks.park(self);
            if (!self.accepts()) return error.Closed;
            if (self.region == null or self.attachment_phase == .detached or self.attachment_phase == .detaching) return;
            self.attachment_phase = .detaching;
            _ = try region.remove();
        }

        pub fn attachRegion(self: *Self, region: z.composition.Region) !void {
            const scope = self.beginCallback() orelse return error.Closed;
            defer scope.end();
            if (self.region != null or self.attachment_phase != .detached) return error.AlreadyAttached;
            const snapshot = try region.snapshot();
            if (snapshot.window.app != self.app.?) return error.ForeignApp;
            if (snapshot.kind != .native) return error.NativeRegionRequired;
            const region_scope = region.beginCallback() orelse return error.Closed;
            defer region_scope.end();
            if (self.attachment_epoch == std.math.maxInt(u64)) return error.GenerationExhausted;
            self.attachment_epoch += 1;
            self.region = region;
            self.provider_window = snapshot.window;
            self.attachment_phase = .attaching;
            region.attach(.{
                .context = self,
                .attach = providerAttach,
                .update = providerUpdate,
                .detach = providerDetach,
                .event = providerEvent,
                .native_parent_destroying = parentDestroying,
            }) catch |err| {
                // Failed provider attach has rolled back its native candidate;
                // it transfers no detach obligation to composition.
                self.region = null;
                self.provider_window = null;
                self.host_parent = null;
                self.attachment_phase = .detached;
                return err;
            };
            if (!self.accepts()) return error.Closed;
            _ = region.snapshot() catch return error.Closed;
            self.attachment_phase = .attached;
        }

        /// No App business ingress is granted by this operation. It can run in
        /// an accepted post during stopping, or after a failed shutdown pass.
        /// Failure retains stable storage and stop responsibility for retry.
        pub fn close(self: *Self) !CloseResult {
            if (self.phase == .closed) return .closed;
            const app = self.app orelse {
                self.phase = .closed;
                return .closed;
            };
            const app_scope = app.beginTeardownCallback();
            defer app_scope.end();
            self.pins += 1;
            self.phase = .closing;
            self.requestRemove();
            self.pins -= 1;
            return self.advanceClose();
        }
        pub fn isClosed(self: *const Self) bool {
            if (self.app) |app| app.assertOwner();
            return self.phase == .fresh or self.phase == .closing or self.phase == .closed;
        }
        pub fn currentRegion(self: *const Self) ?z.composition.Region {
            if (self.attachment_phase != .attached) return null;
            const region = self.region orelse return null;
            _ = region.snapshot() catch return null;
            return region;
        }
        pub fn accepts(self: *const Self) bool {
            const app = self.app orelse return false;
            app.assertOwner();
            return (self.phase == .opening or self.phase == .open) and !self.page_closed and app.phase != .stopping and app.phase != .stopped;
        }
        pub fn beginCallback(self: *Self) ?Scope {
            if (!self.accepts()) return null;
            const app_scope = self.app.?.beginCallback() orelse return null;
            self.pins += 1;
            return .{ .session = self, .app_scope = app_scope };
        }
        pub const Scope = struct {
            session: *Self,
            app_scope: z.AppCallbackScope,
            pub fn end(self: Scope) void {
                const app = self.app_scope.app;
                self.session.release();
                (z.AppCallbackScope{ .app = app }).end();
            }
        };
        fn beginTeardown(self: *Self) Scope {
            const app_scope = self.app.?.beginTeardownCallback();
            self.pins += 1;
            return .{ .session = self, .app_scope = app_scope };
        }
        fn release(self: *Self) void {
            std.debug.assert(self.pins != 0);
            self.pins -= 1;
            if (self.pins != 0 or self.phase != .closing) return;
            const app = self.app orelse return;
            _ = self.advanceClose() catch |err| {
                // The sink can retry close and release self; do not read self
                // again after reporting this captured diagnostic.
                const diagnostic: z.diagnostics.Diagnostic = .{ .domain = .webview, .operation = .webview_teardown, .err = err, .code = if (self.last_hresult < 0) @bitCast(self.last_hresult) else null };
                app.report(diagnostic);
                return;
            };
        }
        fn requestRemove(self: *Self) void {
            const region = self.region orelse return;
            self.attachment_phase = .detaching;
            _ = region.remove() catch false;
        }
        fn advanceClose(self: *Self) !CloseResult {
            if (self.pins != 0 or self.finishing) return .deferred;
            if (self.phase == .closed) return .closed;
            std.debug.assert(self.phase == .closing);
            self.finishing = true;
            errdefer self.finishing = false;
            if (!self.page_closed) {
                self.page_closed = true;
                Hooks.closePage(self);
            }
            if (!self.native_closed) {
                try Hooks.closeHost(self);
                self.native_closed = true;
            }
            // Native shutdown can finish before a closing Window's deferred
            // provider detach. This avoids blocking stopAll before Window flush.
            if (self.stop_token) |token| {
                _ = self.app.?.cancelStop(token) catch |err| {
                    if (err == error.StopInProgress) {
                        self.finishing = false;
                        return .deferred;
                    }
                    return err;
                };
                self.stop_token = null;
            }
            if (self.region != null) {
                self.finishing = false;
                return .deferred;
            }
            self.phase = .closed;
            self.app = null;
            self.finishing = false;
            if (self.opened) if (self.on_closed) |handler| {
                const context = handler.context;
                const notify = handler.notify;
                self.on_closed = null;
                notify(context, self);
                return .closed;
            };
            self.on_closed = null;
            return .closed;
        }
        fn stop(context: *anyopaque) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            const app_scope = self.app.?.beginTeardownCallback();
            defer app_scope.end();
            self.pins += 1;
            self.phase = .closing;
            self.requestRemove();
            self.pins -= 1;
            // A cleared node means stopAll currently owns this callback.
            // A deferred result may only be the old provider detach obligation;
            // native resources have already ended and storage stays alive.
            _ = try self.advanceClose();
        }
        fn providerAttach(context: *anyopaque, region: z.composition.Region) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (!self.accepts()) return error.Closed;
            try Hooks.attach(self, region, try region.snapshot());
        }
        fn providerUpdate(context: *anyopaque, region: z.composition.Region, viewport: z.composition.Viewport) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            const scope = self.beginCallback() orelse return error.Closed;
            defer scope.end();
            if (self.attachment_phase != .attached) return error.Closed;
            try Hooks.update(self, region, viewport, try region.snapshot());
        }
        fn providerDetach(context: *anyopaque, _: z.composition.Region) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const scope = self.beginTeardown();
            defer scope.end();
            self.attachment_phase = .detaching;
            Hooks.detach(self);
            self.region = null;
            self.provider_window = null;
            self.host_parent = null;
            self.attachment_phase = .detached;
        }
        fn parentDestroying(context: *anyopaque, region: z.composition.Region) void {
            const self: *Self = @ptrCast(@alignCast(context));
            // Core keeps the provider alive. A Session scope end here could
            // trigger COM/five-book finalization inside WM_DESTROY: forbidden.
            self.attachment_phase = .detaching;
            Hooks.parentDestroying(self, region);
        }
        fn providerEvent(context: *anyopaque, region: z.composition.Region, event: z.Event) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (event != .resize and event != .window_position) return;
            const scope = self.beginCallback() orelse return;
            defer scope.end();
            if (self.attachment_phase != .attached) return;
            if (event == .window_position) {
                Hooks.parentPosition(self);
            } else {
                const snapshot = region.snapshot() catch return;
                Hooks.update(self, region, snapshot.viewport, snapshot) catch |err| {
                    const app = self.app orelse return;
                    app.report(.{ .domain = .webview, .operation = .webview_geometry, .err = err, .code = if (self.last_hresult < 0) @bitCast(self.last_hresult) else null });
                };
            }
        }
    };
}

const TestEvent = enum { ready };
const TestPage = struct {
    allocator: std.mem.Allocator,
    context: *anyopaque,
    fn init(allocator: std.mem.Allocator, context: *anyopaque, _: *const fn (*anyopaque, *TestPage, TestEvent) void) TestPage {
        return .{ .allocator = allocator, .context = context };
    }
};
const TestSession = Type(TestPage, TestHooks);
const TestContext = struct {
    closed: usize = 0,
    page_closes: usize = 0,
    host_closes: usize = 0,
    fail_close: usize = 0,
    detach: usize = 0,
    remove_during_park: bool = false,
    free_on_closed: bool = false,
    session: ?*TestSession = null,
    close_result: ?TestSession.CloseResult = null,
    fn event(_: *anyopaque, _: *TestPage, _: TestEvent) void {}
    fn onClosed(context: *anyopaque, session: *TestSession) void {
        const self: *TestContext = @ptrCast(@alignCast(context));
        self.closed += 1;
        if (self.free_on_closed) {
            self.session = null;
            session.page.allocator.destroy(session);
        }
    }
    fn closePost(context: *anyopaque) void {
        const self: *TestContext = @ptrCast(@alignCast(context));
        self.close_result = self.session.?.close() catch unreachable;
    }
};
const TestHooks = struct {
    const Options = struct { fail_open: bool = false };
    const Event = TestEvent;
    fn state(session: *TestSession) *TestContext {
        return @ptrCast(@alignCast(session.page.context));
    }
    fn open(session: *TestSession, options: Options, _: TestSession.PixelSize) !void {
        session.native_host = @ptrFromInt(1);
        if (options.fail_open) return error.InjectedOpen;
    }
    fn closePage(session: *TestSession) void {
        state(session).page_closes += 1;
    }
    fn closeHost(session: *TestSession) !void {
        const context = state(session);
        context.host_closes += 1;
        if (context.fail_close != 0) {
            context.fail_close -= 1;
            session.last_hresult = @bitCast(@as(u32, 0x80070005));
            return error.InjectedClose;
        }
        session.native_host = null;
    }
    fn attach(_: *TestSession, _: z.composition.Region, _: z.composition.Snapshot) !void {}
    fn update(_: *TestSession, _: z.composition.Region, _: z.composition.Viewport, _: z.composition.Snapshot) !void {}
    fn detach(session: *TestSession) void {
        state(session).detach += 1;
    }
    fn park(session: *TestSession) !void {
        if (state(session).remove_during_park) _ = try session.region.?.remove();
    }
    fn parentPosition(_: *TestSession) void {}
    fn parentDestroying(_: *TestSession, _: z.composition.Region) void {}
};

test "session last callback pin defers close and notifies once" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var context: TestContext = .{};
    var session = TestSession.init(std.testing.allocator, &context, TestContext.event);
    try session.open(app, .{ .page = .{}, .on_closed = .{ .context = &context, .notify = TestContext.onClosed } });
    const scope = session.beginCallback().?;
    try std.testing.expectEqual(TestSession.CloseResult.deferred, try session.close());
    try std.testing.expectEqual(@as(usize, 0), context.page_closes);
    scope.end();
    try std.testing.expectEqual(@as(usize, 1), context.page_closes);
    try std.testing.expectEqual(@as(usize, 1), context.host_closes);
    try std.testing.expectEqual(@as(usize, 1), context.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
    try std.testing.expectEqual(TestSession.CloseResult.closed, try session.close());
}

test "session accepted close post runs during App deinit and may free session" {
    const app = try z.App.init(std.testing.allocator);
    var context: TestContext = .{ .free_on_closed = true };
    const session = try std.testing.allocator.create(TestSession);
    session.* = TestSession.init(std.testing.allocator, &context, TestContext.event);
    context.session = session;
    try session.open(app, .{ .page = .{}, .on_closed = .{ .context = &context, .notify = TestContext.onClosed } });
    try app.post(.{ .context = &context, .call = TestContext.closePost });
    app.quit();
    try std.testing.expect(session.beginCallback() == null);
    app.deinit();
    try std.testing.expect(context.session == null);
    try std.testing.expectEqual(TestSession.CloseResult.closed, context.close_result.?);
    try std.testing.expectEqual(@as(usize, 1), context.closed);
}

test "session failed stop keeps node and explicit shutdown retry does not repeat page completions" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var context: TestContext = .{ .fail_close = 1 };
    var session = TestSession.init(std.testing.allocator, &context, TestContext.event);
    try session.open(app, .{ .page = .{}, .on_closed = .{ .context = &context, .notify = TestContext.onClosed } });
    app.quit();
    try std.testing.expectError(error.InjectedClose, app.finishShutdown());
    try std.testing.expectEqual(@as(usize, 1), app.resourceStats().stop_participants);
    try std.testing.expectEqual(@as(usize, 1), context.page_closes);
    try std.testing.expectEqual(@as(usize, 0), context.closed);
    // Native retry may finish, but the failed StopParticipant is still owned by
    // its manager. No closed notification can release that node prematurely.
    try std.testing.expectEqual(TestSession.CloseResult.deferred, try session.close());
    try std.testing.expectEqual(@as(usize, 0), context.closed);
    try app.finishShutdown();
    try std.testing.expectEqual(@as(usize, 1), context.closed);
    try std.testing.expectEqual(@as(usize, 1), context.page_closes);
    try std.testing.expectEqual(@as(usize, 2), context.host_closes);
}

test "session failed construction retains retry storage without closed notification" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var context: TestContext = .{ .fail_close = 1 };
    var session = TestSession.init(std.testing.allocator, &context, TestContext.event);
    try std.testing.expectError(error.InjectedOpen, session.open(app, .{ .page = .{ .fail_open = true }, .on_closed = .{ .context = &context, .notify = TestContext.onClosed } }));
    try std.testing.expectEqual(TestSession.Phase.closing, session.phase);
    try std.testing.expectEqual(@as(usize, 1), app.resourceStats().stop_participants);
    try std.testing.expectEqual(TestSession.CloseResult.closed, try session.close());
    try std.testing.expectEqual(@as(usize, 0), context.closed);
}

test "session stop closes page before a closing Window deferred provider detach" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var context: TestContext = .{};
    var session = TestSession.init(std.testing.allocator, &context, TestContext.event);
    try session.open(app, .{ .page = .{}, .on_closed = .{ .context = &context, .notify = TestContext.onClosed } });
    const window = try app.createWindow(.{});
    const owner = try z.composition.Owner.create(std.testing.allocator, window, .{});
    defer owner.close() catch unreachable;
    const region = try owner.reserve(.{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 60 } });
    try session.attachRegion(region);
    const pin = window.beginCallback().?;
    _ = try window.destroy();
    app.quit();
    pin.end();
    try app.finishShutdown();
    try std.testing.expectEqual(@as(usize, 1), context.page_closes);
    try std.testing.expectEqual(@as(usize, 1), context.detach);
    try std.testing.expectEqual(@as(usize, 1), context.closed);
}

test "session park pins old Region through foreign removal without restoring a detached phase" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var context: TestContext = .{ .remove_during_park = true };
    var session = TestSession.init(std.testing.allocator, &context, TestContext.event);
    try session.open(app, .{ .page = .{} });
    const window = try app.createWindow(.{});
    const owner = try z.composition.Owner.create(std.testing.allocator, window, .{});
    defer owner.close() catch unreachable;
    try session.attachRegion(try owner.reserve(.{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 60 } }));
    try session.park();
    try std.testing.expectEqual(TestSession.AttachmentPhase.detached, session.attachment_phase);
    try std.testing.expect(session.region == null and context.detach == 1);
    try session.attachRegion(try owner.reserve(.{ .bounds = .{ .x = 5, .y = 10, .width = 100, .height = 60 } }));
    try std.testing.expectEqual(TestSession.CloseResult.closed, try session.close());
    _ = try window.destroy();
}
