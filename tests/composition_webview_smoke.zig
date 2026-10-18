const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const ui = @import("ziggurat_ui");
const Fixture = @import("scheme_smoke.zig").Fixture;
const Watchdog = @import("watchdog.zig").Watchdog;
const w = @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

const Case = struct {
    state: *State,
    index: usize,
    expected: Dimensions = undefined,
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *Case = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                self.state.fixture.capture(view) catch |err| return self.state.fail(err);
                if (self.index == 2) {
                    const region = self.state.regions[2];
                    if (!(region.remove() catch |err| return self.state.fail(err))) return self.state.fail(error.RemoveFailed);
                    if (view.native == null or view.config == null or view.window == null) return self.state.fail(error.PrematureDetach);
                    std.testing.expectError(error.Closed, view.setZoom(1.5)) catch |err| return self.state.fail(err);
                    self.state.callback_removed = true;
                    self.state.queue();
                }
            },
            .failed => |hr| {
                std.debug.print("composition native failure view={d} HRESULT=0x{x:0>8}\n", .{ self.index, @as(u32, @bitCast(hr)) });
                self.state.fail(error.NativeFailure);
            },
            .process_failed => self.state.fail(error.NativeProcessFailure),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, _: *web.View, value: web.PageEvent) void {
        const self: *Case = @ptrCast(@alignCast(ptr));
        if (value != .completed) return;
        if (!value.completed.success) return self.state.fail(error.NavigationFailed);
        if (self.index == 3) {
            self.state.legacy_loaded = true;
            return self.state.queue();
        }
        if (self.index >= 2) return self.state.fail(error.RemovedPageCallback);
        self.state.loaded[self.index] = true;
        self.state.queue();
    }
    fn script(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Case = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.state.fail(error.MissingDimensions);
        const parsed = std.json.parseFromSlice(Dimensions, self.state.app.allocator, result.json, .{}) catch |err| return self.state.fail(err);
        defer parsed.deinit();
        const actual = parsed.value;
        if (@abs(actual.width - self.expected.width) > 2 or @abs(actual.height - self.expected.height) > 2 or actual.marker != self.expected.marker or !std.mem.eql(u8, actual.title, self.expected.title)) {
            std.debug.print("composition dimensions view={d} actual={any} expected={any}\n", .{ self.index, actual, self.expected });
            return self.state.fail(error.WrongViewport);
        }
        self.state.evaluated += 1;
        if (self.state.evaluated == 2) self.state.queue();
    }
    fn held(ptr: *anyopaque, result: web.resources.Result) void {
        const self: *Case = @ptrCast(@alignCast(ptr));
        if (result != .detached) return self.state.fail(error.ResourceDidNotDetach);
        self.state.terminals += 1;
        if (self.state.views[0].config == null) self.state.fail(error.ConfigReleasedInCompletion);
    }
    fn unexpectedScript(_: *anyopaque, _: web.ScriptResult) void {
        @panic("rejected script transferred completion ownership");
    }
    fn unexpectedResource(_: *anyopaque, _: web.resources.Result) void {
        @panic("rejected resource transferred completion ownership");
    }
    fn resource(ptr: *anyopaque, request: web.ResourceRequest, responder: *web.Responder) void {
        const self: *Case = @ptrCast(@alignCast(ptr));
        const state = self.state;
        if (std.mem.eql(u8, request.path, "/hold")) {
            state.held_id = responder.deferResponse(.{ .timeout_ms = 10_000, .completion = .{ .context = self, .complete = held } }) catch |err| return state.fail(err);
            state.queue();
        } else if (std.mem.eql(u8, request.path, "/remove")) {
            if (!(state.regions[0].remove() catch |err| return state.fail(err))) return state.fail(error.RemoveFailed);
            const view = &state.views[0];
            if (view.native == null or view.window == null or view.config == null or state.window.isClosed()) return state.fail(error.PrematureDetach);
            std.testing.expectError(error.Closed, responder.respond(.{ .bytes = "late" })) catch |err| return state.fail(err);
            std.testing.expectError(error.Closed, responder.deferResponse(.{ .completion = .{ .context = self, .complete = unexpectedResource } })) catch |err| return state.fail(err);
            var file: web.OwnedFileResponse = undefined;
            // Closed must be decided before touching a supplied owning result.
            std.testing.expectError(error.Closed, responder.respondFile(&file, .{})) catch |err| return state.fail(err);
            std.testing.expectError(error.Closed, view.evaluateJS("1", .{}, .{ .context = self, .complete = unexpectedScript })) catch |err| return state.fail(err);
            std.testing.expectError(error.Closed, view.postFor(state.old_page.?, "late")) catch |err| return state.fail(err);
            std.testing.expectError(error.Closed, view.setZoom(1.5)) catch |err| return state.fail(err);
            if (view.pageId() != null) return state.fail(error.RemovedPageRemainedCurrent);
            var owned = web.resources.OwnedResponse.init(state.app.allocator, .{ .bytes = "retained" }, 32) catch |err| return state.fail(err);
            defer owned.deinit();
            std.testing.expectError(error.Closed, view.respondOwned(state.held_id.?, &owned)) catch |err| return state.fail(err);
            if (owned.storage == null) return state.fail(error.FailedResponseConsumedOwner);
            state.removed = true;
            state.queue();
        }
    }
};
const Dimensions = struct { width: f64, height: f64, marker: u32, title: []const u8 };
const State = struct {
    app: *z.App,
    window: z.Window,
    owner: *z.composition.Owner,
    fixture: *Fixture,
    background: ui.Context = undefined,
    backdrop: z.composition.Region = undefined,
    draws: u32 = 0,
    positions: u32 = 0,
    views: [4]web.View = undefined,
    cases: [4]Case = undefined,
    legacy_window: ?z.Window = null,
    legacy_loaded: bool = false,
    regions: [3]z.composition.Region = undefined,
    loaded: [2]bool = @splat(false),
    old_page: ?web.PageId = null,
    other_page: ?web.PageId = null,
    held_id: ?web.ResourceRequestId = null,
    phase: enum { loading, initial, updated, reload_wait, reloaded, holding, remove_wait, reattach_wait, reattached } = .loading,
    evaluated: u32 = 0,
    terminals: u32 = 0,
    queued: bool = false,
    removed: bool = false,
    callback_removed: bool = false,
    done: bool = false,
    failure: ?anyerror = null,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        frame.clear(0x234567);
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn backgroundInput(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (event == .window_position) self.positions += 1;
        return false;
    }
    fn paintBackdrop(self: *State) !void {
        const before = self.draws;
        _ = w.SendMessageW(self.window.nativeHandle(), w.WM_PAINT, 0, 0);
        try std.testing.expect(self.draws > before and self.background.gdi_frames > 0 and self.background.renderer.dc != null);
        try std.testing.expectEqual(@as(w.COLORREF, 0x674523), w.GetPixel(self.background.renderer.dc, 2, 2));
        const size = try self.window.contentSize();
        try std.testing.expectEqual(size.width, self.background.renderer.width);
        try std.testing.expectEqual(size.height, self.background.renderer.height);
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) {
            self.failure = err;
            std.debug.print("composition WebView phase={s}: {s}\n", .{ @tagName(self.phase), @errorName(err) });
        }
        self.app.quit();
    }
    fn options(self: *State, index: usize, title: []const u8) web.Options {
        return .{ .html = title, .user_data_folder = self.fixture.profile.?, .local = .{ .on_resource = .{ .context = &self.cases[index], .handle = Case.resource } }, .page_listener = .{ .context = &self.cases[index], .event = Case.page } };
    }
    fn queue(self: *State) void {
        if (self.queued or self.done or self.failure != null) return;
        self.queued = true;
        self.app.post(.{ .context = self, .call = advance }) catch |err| self.fail(err);
    }
    fn measure(self: *State, width: f64, height: f64, marker: u32, title: []const u8, other_marker: u32) !void {
        self.evaluated = 0;
        self.cases[0].expected = .{ .width = width, .height = height, .marker = marker, .title = title };
        self.cases[1].expected = .{ .width = 180, .height = 120, .marker = other_marker, .title = "two" };
        for (0..2) |index| _ = try self.views[index].evaluateJS("window.marker=(window.marker||0)+1;({width:innerWidth,height:innerHeight,marker:window.marker,title:document.title})", .{}, .{ .context = &self.cases[index], .complete = Case.script });
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        if (self.done or self.failure != null) return;
        self.advanceInner() catch |err| self.fail(err);
    }
    fn advanceInner(self: *State) !void {
        switch (self.phase) {
            .loading => {
                if (!self.loaded[0] or !self.loaded[1] or !self.legacy_loaded) return;
                self.old_page = self.views[0].pageId().?;
                self.other_page = self.views[1].pageId().?;
                self.phase = .initial;
                try self.measure(160, 90, 1, "one", 1);
            },
            .initial => {
                if (self.evaluated != 2) return;
                try self.paintBackdrop();
                const bounds = try self.window.clientBounds();
                const position = bounds.position.?;
                const previous_positions = self.positions;
                for (self.views[0..2]) |*view| view.last_hresult = @bitCast(@as(u32, 0x80004005));
                try self.window.setClientBounds(.{ .position = .{ .x = position.x + 7, .y = position.y + 9 }, .width = bounds.width, .height = bounds.height });
                try std.testing.expect(self.positions > previous_positions);
                for (self.views[0..2]) |*view| try std.testing.expect(view.last_hresult >= 0);
                try std.testing.expect(!std.meta.eql(position, (try self.window.clientBounds()).position.?));
                const legacy = self.legacy_window.?;
                self.views[3].last_hresult = @bitCast(@as(u32, 0x80004005));
                try legacy.resize(121, 81);
                try std.testing.expect(self.views[3].last_hresult >= 0);
                try expectChild(legacy, .{ .x = 0, .y = 0, .width = 121, .height = 81 }, true);
                const legacy_bounds = try legacy.clientBounds();
                self.views[3].last_hresult = @bitCast(@as(u32, 0x80004005));
                try legacy.setClientBounds(.{ .position = .{ .x = legacy_bounds.position.?.x + 11, .y = legacy_bounds.position.?.y + 13 }, .width = legacy_bounds.width, .height = legacy_bounds.height });
                try std.testing.expect(self.views[3].last_hresult >= 0);
                _ = try legacy.destroy();
                try expectChild(self.window, .{ .x = 20, .y = 15, .width = 160, .height = 90 }, true);
                try self.window.resize(520, 300);
                try self.paintBackdrop();
                try expectChild(self.window, .{ .x = 20, .y = 15, .width = 160, .height = 90 }, true);
                try self.regions[0].update(.{ .bounds = .{ .x = 40, .y = 35, .width = 190, .height = 110 } });
                try self.regions[1].update(.{ .bounds = .{ .x = 250, .y = 30, .width = 180, .height = 120 }, .visible = false });
                try expectChild(self.window, .{ .x = 250, .y = 30, .width = 180, .height = 120 }, false);
                self.phase = .updated;
                try self.measure(190, 110, 2, "one", 2);
            },
            .updated => {
                if (self.evaluated != 2) return;
                try std.testing.expect(self.views[3].window == null and self.views[3].native == null and self.legacy_window.?.isClosed());
                try self.regions[1].update(.{ .bounds = .{ .x = 250, .y = 30, .width = 180, .height = 120 } });
                try expectChild(self.window, .{ .x = 250, .y = 30, .width = 180, .height = 120 }, true);
                self.loaded[0] = false;
                self.phase = .reload_wait;
                try self.views[0].reload(self.options(0, "<title>replacement</title>"));
            },
            .reload_wait => {
                if (!self.loaded[0]) return;
                try std.testing.expect(self.old_page.?.generation != self.views[0].pageId().?.generation);
                try std.testing.expectEqual(self.other_page.?, self.views[1].pageId().?);
                try expectChild(self.window, .{ .x = 40, .y = 35, .width = 190, .height = 110 }, true);
                self.old_page = self.views[0].pageId();
                self.phase = .reloaded;
                try self.measure(190, 110, 1, "replacement", 3);
            },
            .reloaded => {
                if (self.evaluated != 2) return;
                self.phase = .holding;
                _ = try self.views[0].evaluateJS("fetch('/hold')", .{}, .{ .context = self, .complete = ignored });
            },
            .holding => {
                if (self.held_id == null) return;
                self.phase = .remove_wait;
                _ = try self.views[0].evaluateJS("fetch('/remove')", .{}, .{ .context = self, .complete = ignored });
            },
            .remove_wait => {
                if (!self.removed) return;
                try std.testing.expectEqual(@as(u32, 1), self.terminals);
                try std.testing.expect(self.views[0].native == null and self.views[0].window == null);
                try std.testing.expect(try self.backdrop.remove());
                try std.testing.expect(self.background.window == null and self.background.renderer.dc == null);
                const before = self.draws;
                _ = w.SendMessageW(self.window.nativeHandle(), w.WM_PAINT, 0, 0);
                try std.testing.expectEqual(before, self.draws);
                try expectChild(self.window, .{ .x = 250, .y = 30, .width = 180, .height = 120 }, true);
                self.backdrop = try self.background.attachBackdrop(self.owner);
                try self.paintBackdrop();
                const stale = self.regions[0];
                try std.testing.expectError(error.Closed, stale.snapshot());
                try std.testing.expect(!try stale.remove());
                self.regions[0] = try self.owner.reserve(.{ .bounds = .{ .x = 10, .y = 25, .width = 200, .height = 100 } });
                try std.testing.expectEqual(stale.index, self.regions[0].index);
                try std.testing.expect(stale.generation != self.regions[0].generation);
                self.loaded[0] = false;
                self.phase = .reattach_wait;
                try self.views[0].attachRegion(self.regions[0], self.options(0, "<title>reattached</title>"));
                try std.testing.expectError(error.Closed, stale.update(.{ .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 } }));
            },
            .reattach_wait => {
                if (!self.loaded[0] or !self.callback_removed) return;
                try std.testing.expect(self.views[2].native == null and self.views[2].window == null);
                self.phase = .reattached;
                try self.measure(200, 100, 1, "reattached", 4);
            },
            .reattached => {
                if (self.evaluated != 2) return;
                self.done = true;
                const closed = try self.window.destroy();
                try std.testing.expect(closed == .closed or closed == .deferred);
                self.app.quit();
            },
        }
    }
    fn ignored(_: *anyopaque, _: web.ScriptResult) void {}
};

fn expectChild(window: z.Window, bounds: z.Rect, visible: bool) !void {
    const size = try window.contentSize();
    const parent = window.nativeHandle();
    var child = w.GetWindow(parent, w.GW_CHILD);
    while (child != null) : (child = w.GetWindow(child, w.GW_HWNDNEXT)) {
        var rect: w.RECT = undefined;
        if (w.GetWindowRect(child, &rect) == 0) continue;
        _ = w.MapWindowPoints(null, parent, @ptrCast(&rect), 2);
        const expected = [_]i32{ @intFromFloat(@round(bounds.x * size.scale)), @intFromFloat(@round(bounds.y * size.scale)), @intFromFloat(@round((bounds.x + bounds.width) * size.scale)), @intFromFloat(@round((bounds.y + bounds.height) * size.scale)) };
        if (rect.left == expected[0] and rect.top == expected[1] and rect.right == expected[2] and rect.bottom == expected[3]) {
            const style = w.GetWindowLongPtrW(child, w.GWL_STYLE);
            if (((style & w.WS_VISIBLE) != 0) == visible) return;
        }
    }
    return error.NativeViewportNotFound;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var temporary = std.testing.tmpDir(.{});
    var fixture: Fixture = .{ .allocator = allocator, .temporary = &temporary };
    var worker = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    worker.join();
    defer {
        fixture.cleanup = true;
        fixture.err = null;
        worker = std.Thread.spawn(.{}, Fixture.run, .{&fixture}) catch @panic("cleanup worker unavailable");
        worker.join();
        if (fixture.profile) |profile| allocator.free(profile);
        if (!fixture.closed) temporary.cleanup();
        if (fixture.err) |err| std.debug.panic("composition fixture cleanup: {s}", .{@errorName(err)});
    }
    if (fixture.err) |err| return err;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 480, .height = 260 });
    const owner = try z.composition.Owner.create(allocator, window, .{ .capacity = 4 });
    defer {
        if (!window.isClosed()) _ = window.destroy() catch @panic("window cleanup failed");
        owner.close() catch @panic("composition owner did not detach");
    }
    var state: State = .{ .app = app, .window = window, .owner = owner, .fixture = &fixture };
    state.background = ui.Context.init(&state, State.draw, State.action);
    state.background.render_mode = .gdi;
    state.background.semantics_enabled = false;
    state.background.on_input = State.backgroundInput;
    state.backdrop = try state.background.attachBackdrop(owner);
    for (0..4) |index| {
        state.cases[index] = .{ .state = &state, .index = index };
        state.views[index] = web.View.init(allocator, &state.cases[index], Case.event);
    }
    state.regions[0] = try owner.reserve(.{ .bounds = .{ .x = 20, .y = 15, .width = 160, .height = 90 } });
    state.regions[1] = try owner.reserve(.{ .bounds = .{ .x = 250, .y = 30, .width = 180, .height = 120 } });
    state.regions[2] = try owner.reserve(.{ .bounds = .{ .x = 0, .y = 180, .width = 30, .height = 30 } });
    const invalid = state.options(0, "");
    var failing = invalid;
    failing.zoom = 0;
    try std.testing.expectError(error.InvalidZoom, state.views[0].attachRegion(state.regions[0], failing));
    try std.testing.expect(state.views[0].config == null and state.views[0].window == null);
    try state.views[0].attachRegion(state.regions[0], state.options(0, "<title>one</title>"));
    fixture.runtime_started = true;
    try state.views[1].attachRegion(state.regions[1], state.options(1, "<title>two</title>"));
    try state.views[2].attachRegion(state.regions[2], state.options(2, "<title>pending removal</title>"));
    const abandoned = state.regions[2];
    try std.testing.expect(try abandoned.remove());
    try std.testing.expect(state.views[2].window == null and state.views[2].native == null);
    state.regions[2] = try owner.reserve(.{ .bounds = .{ .x = 0, .y = 180, .width = 30, .height = 30 } });
    try std.testing.expectEqual(abandoned.index, state.regions[2].index);
    try std.testing.expect(abandoned.generation != state.regions[2].generation);
    try state.views[2].attachRegion(state.regions[2], state.options(2, "<title>removed</title>"));
    state.legacy_window = try app.createWindow(.{ .width = 100, .height = 80 });
    try state.views[3].attach(state.legacy_window.?, state.options(3, "<title>legacy</title>"));
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(state.done and !watchdog.expired and state.terminals == 1 and state.callback_removed);
    const counts = web.resourceCounts();
    try std.testing.expectEqual(@as(u32, 0), counts.states);
    try std.testing.expectEqual(@as(u32, 0), counts.handlers);
    try std.testing.expectEqual(@as(u32, 0), counts.controllers);
    try std.testing.expectEqual(@as(u32, 0), web.deferredResourceCount());
    try std.testing.expect(state.background.window == null and state.background.renderer.dc == null and state.background.renderer.bitmap == null and state.background.renderer.pixels == null);
    std.debug.print("composition WebView passed: GDI backdrop + two pages, bounds/move/resize, hide/show, reload, pending/callback removal, Closed responders, slot reuse, COM/GDI=0\n", .{});
}
