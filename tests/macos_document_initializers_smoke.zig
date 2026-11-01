const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;
pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);

const origin = "https://app.ziggurat.invalid";
const a = [_][]const u8{
    "window.__zigInitializer=['甲😀'];var bodyLocal=1;return;window.__zigInitializer.push('unreachable');",
    "window.__zigInitializer.push('A2:'+typeof bodyLocal,'bridge:'+typeof chrome.webview.postMessage);",
};
const b = [_][]const u8{
    "window.__zigInitializer=['B1'];var bodyLocal=1;return;window.__zigInitializer.push('unreachable');",
    "window.__zigInitializer.push('B2:'+typeof bodyLocal,'bridge:'+typeof chrome.webview.postMessage);",
};
const throwing = [_][]const u8{ "window.__zigInitializer=['T1'];throw Error('fixture-initializer-throw');", "window.__zigInitializer.push('unreachable');" };
/// Reports what the initializers left before any page script, and whether a
/// child frame saw them (top-frame initializers must not run there).
const page_html = "<!doctype html><body><script>const trace=Array.isArray(window.__zigInitializer)?window.__zigInitializer.slice():[];const child=document.createElement('iframe');child.onload=()=>chrome.webview.postMessage(JSON.stringify({trace,origin:location.origin,frame:typeof child.contentWindow.__zigInitializer==='undefined'}));document.body.appendChild(child)</script>";

const Phase = enum { a, b, throwing, empty, foreign, any, done };
const Payload = struct { trace: []const []const u8, origin: []const u8, frame: bool };

/// Document initializers through one page: the attach set at document start
/// in the page world with the bridge, replacement for later documents only,
/// a throwing body, an empty set, an origin that does not match, the "*"
/// origin, and native records released after close.
const State = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    window: z.Window,
    view: web.View = undefined,
    phase: Phase = .a,
    failure: ?anyerror = null,
    entries: [2]web.DocumentInitializer = undefined,
    input_origins: [1][]const u8 = undefined,
    ready: usize = 0,
    messages: usize = 0,
    installed: usize = 0,
    queued: bool = false,
    fn source(self: *State, bodies: [2][]const u8, allowed: []const u8) []const web.DocumentInitializer {
        self.input_origins[0] = allowed;
        for (&self.entries, bodies) |*entry, body| entry.* = .{ .body = body, .origins = &self.input_origins };
        return &self.entries;
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("macOS initializer {s}: {s}\n", .{ @tagName(self.phase), @errorName(err) });
        self.app.quit();
    }
    fn event(ptr: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .ready => {
                self.ready += 1;
                if (view.initializer_domain == null) self.fail(error.MissingInitializerDomain);
            },
            .message => |bytes| self.message(bytes) catch |err| self.fail(err),
            .failed => {
                std.debug.print("initializer native: {any}\n", .{view.nativeFailure()});
                self.fail(error.NativeFailed);
            },
            .process_failed => self.fail(error.UnexpectedProcessFailure),
            else => {},
        }
    }
    fn message(self: *State, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Payload, self.allocator, bytes, .{});
        defer parsed.deinit();
        const value = parsed.value;
        const expected: []const []const u8 = switch (self.phase) {
            .a => &.{ "甲😀", "A2:undefined", "bridge:function" },
            .b, .any => &.{ "B1", "B2:undefined", "bridge:function" },
            .throwing => &.{"T1"},
            .empty, .foreign => &.{},
            .done => return error.UnexpectedMessage,
        };
        errdefer std.debug.print("initializer payload={s}\n", .{bytes});
        try std.testing.expect(value.frame and value.trace.len == expected.len);
        for (value.trace, expected) |actual, wanted| try std.testing.expectEqualStrings(wanted, actual);
        try std.testing.expectEqualStrings(origin, value.origin);
        self.messages += 1;
        if (self.queued) return error.UnexpectedMessage;
        self.queued = true;
        // Leave the message callback before replacing or navigating.
        try self.app.post(.{ .context = self, .call = advance });
    }
    fn advance(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.queued = false;
        self.advanceInner() catch |err| self.fail(err);
    }
    fn completion(ptr: *anyopaque, result: web.InitializerResult) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (result != .installed or result.installed != self.installed + 1) return self.fail(error.InvalidReplacementResult);
        self.installed += 1;
    }
    fn replace(self: *State, entries: []const web.DocumentInitializer, next: Phase) !void {
        const before = self.installed;
        const replacement = try self.view.replaceDocumentInitializers(entries, .{ .context = self, .complete = completion });
        if (self.failure) |err| return err;
        // Installation is complete before the call returns; nothing is left
        // to cancel.
        try std.testing.expect(self.installed == before + 1);
        try std.testing.expect(!(try replacement.cancel()));
        // A replacement changes later documents only.
        try std.testing.expect(self.view.pageId() != null);
        self.phase = next;
        try self.view.refresh();
    }
    fn advanceInner(self: *State) !void {
        switch (self.phase) {
            .a => try self.replace(self.source(b, origin), .b),
            .b => try self.replace(self.source(throwing, origin), .throwing),
            .throwing => try self.replace(&.{}, .empty),
            .empty => try self.replace(self.source(b, "https://other.invalid"), .foreign),
            .foreign => try self.replace(self.source(b, web.document_initializers.any_origin), .any),
            .any => {
                self.phase = .done;
                _ = try self.window.destroy();
                self.app.quit();
            },
            .done => return error.UnexpectedAdvance,
        }
    }
};

/// The page's records, initializer budgets included, outlast close only until
/// the engine lets go of the view.
const Drain = struct {
    app: *z.App,
    rounds: usize = 0,
    fn tick(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const counts = web.resourceCounts();
        const initializer = web.initializerNativeCounts();
        if (counts.states == 0 and counts.handlers == 0 and counts.controllers == 0 and std.meta.eql(initializer, web.InitializerNativeCounts{})) return self.app.quit();
        self.rounds += 1;
        if (self.rounds == 3000) {
            std.debug.print("initializer records remain: budgets={d} owners={d} operations={d}\n", .{ initializer.budgets, initializer.owners, initializer.handlers });
            return self.app.quit();
        }
        zio.sleep(std.time.ns_per_ms);
        self.app.post(.{ .context = self, .call = tick }) catch self.app.quit();
    }
};

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .app = app, .allocator = allocator, .window = try app.createWindow(.{ .width = 160, .height = 100 }) };
    state.view = web.View.init(allocator, &state, State.event);
    try state.view.attach(state.window, .{ .html = page_html, .storage = .ephemeral, .local = .{}, .document_initializers = state.source(a, origin) });
    // The View owns copies; later caller changes reach no document.
    state.entries[0].body = "throw Error('changed-before-first-load')";
    state.input_origins[0] = "https://changed.invalid";
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired);
    try std.testing.expect(state.phase == .done and state.messages == 6 and state.installed == 5 and state.ready == 1);
    std.debug.print("macOS initializer: ready={d} messages={d} installed={d}\n", .{ state.ready, state.messages, state.installed });
}

fn drain(allocator: std.mem.Allocator) !void {
    // A stopped App takes no posts, so a fresh one turns the run loop.
    const app = try z.App.init(allocator);
    defer app.deinit();
    var value: Drain = .{ .app = app };
    try app.post(.{ .context = &value, .call = Drain.tick });
    try app.run();
    const counts = web.resourceCounts();
    if (counts.states != 0 or counts.handlers != 0 or counts.controllers != 0) return error.ViewRecordsRemain;
    if (!std.meta.eql(web.initializerNativeCounts(), web.InitializerNativeCounts{})) return error.InitializerRecordsRemain;
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    try run(allocator);
    try drain(allocator);
    std.debug.print("macOS initializers: document start, page world, top frame, origins, replacement, refs=0\n", .{});
}
