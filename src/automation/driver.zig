//! Drives a running App for the protocol. Requests come from the threads of
//! connections; each hops to the main thread through `App.post` for what it
//! touches, and waits there for the answer. A window of native UI is one
//! whose content is a view `Host`; a page is one whose content is a WebView.
//! Both are found from the window's content, so the app registers nothing.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const options = @import("ziggurat_automation_options");
const webview = if (options.webview) @import("ziggurat_webview") else struct {};
const protocol = @import("protocol.zig");
const tree = @import("tree.zig");
const png = @import("png.zig");

const Failure = protocol.Failure;
const Error = protocol.Error;
const fail = protocol.fail;

/// How often `idle`, and `tree` waiting for a laid-out frame, look again.
const poll_ns = 5 * std.time.ns_per_ms;
/// How long `tree` waits for a frame that lays the view out.
const layout_wait_ns = 2 * std.time.ns_per_s;
/// How long a script may run, as `eval` and `idle` on a page run them.
const script_timeout_ms = 30_000;
/// Windows `windows` lists at most.
const max_windows = 256;

pub const Driver = struct {
    app: *z.App,
    /// The IDs the protocol gives windows, in the order it first saw them.
    /// Main thread only.
    ids: std.ArrayList(Entry) = .empty,
    next_id: u64 = 1,
    allocator: std.mem.Allocator,

    const Entry = struct { window: z.diagnostics.WindowId, id: u64 };

    pub fn init(allocator: std.mem.Allocator, app: *z.App) Driver {
        return .{ .app = app, .allocator = allocator };
    }
    /// After the app's run returned: no request reaches it any more.
    pub fn deinit(self: *Driver) void {
        self.ids.deinit(self.allocator);
    }

    pub fn driver(self: *Driver) protocol.Driver {
        return .{ .context = self, .vtable = &vtable };
    }
    const vtable: protocol.Driver.VTable = .{
        .windows = windowsCall,
        .tree = treeCall,
        .act = actCall,
        .input = inputCall,
        .menu = menuCall,
        .capture = captureCall,
        .eval = evalCall,
        .idle = idleCall,
    };

    /// Runs `function(context)` on the main thread and waits for it.
    /// `error.Quit` once the app no longer takes tasks.
    fn onMain(self: *Driver, context: anytype, comptime function: fn (@TypeOf(context)) void) Error!void {
        const Call = struct {
            context: @TypeOf(context),
            done: zio.ResetEvent = .{},
            fn run(pointer: *anyopaque) void {
                const call: *@This() = @ptrCast(@alignCast(pointer));
                function(call.context);
                call.done.set();
            }
        };
        var call: Call = .{ .context = context };
        self.app.post(.{ .context = &call, .call = Call.run }) catch return error.Quit;
        call.done.wait();
    }

    /// The ID of `window`, given one the first time it is seen. Main thread.
    fn idOf(self: *Driver, window: z.Window) error{OutOfMemory}!u64 {
        const key = window.diagnosticId();
        for (self.ids.items) |entry| if (std.meta.eql(entry.window, key)) return entry.id;
        // Forget windows that closed, so the table follows the open ones.
        var at: usize = 0;
        while (at < self.ids.items.len) {
            if (self.app.findWindow(self.ids.items[at].window) == null) _ = self.ids.orderedRemove(at) else at += 1;
        }
        try self.ids.append(self.allocator, .{ .window = key, .id = self.next_id });
        self.next_id += 1;
        return self.next_id - 1;
    }

    /// The open windows, oldest first. Main thread.
    fn openWindows(self: *Driver, storage: []z.Window) ![]z.Window {
        const list = try self.app.listWindows(storage);
        // The App lists the newest first; give IDs in the order they opened.
        std.mem.reverse(z.Window, list);
        for (list) |window| _ = try self.idOf(window);
        return list;
    }

    /// The window of `id`, or for 0 the focused window, else the first.
    /// Main thread.
    fn resolve(self: *Driver, arena: std.mem.Allocator, id: u64, failure: *Failure) Error!z.Window {
        var storage: [max_windows]z.Window = undefined;
        const list = self.openWindows(&storage) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(failure, arena, .failed, "the app has more than {d} windows", .{max_windows}),
        };
        if (id == 0) {
            for (list) |window| if ((window.state() catch continue).focused) return window;
            if (list.len != 0) return list[0];
            return fail(failure, arena, .no_window, "the app has no window", .{});
        }
        for (self.ids.items) |entry| if (entry.id == id) {
            if (self.app.findWindow(entry.window)) |window| return window;
        };
        return fail(failure, arena, .no_window, "no window {d}", .{id});
    }

    /// A window's content, as the protocol drives it. Main thread.
    const Target = union(enum) {
        host: *view.Host,
        page: if (options.webview) *webview.View else void,
        other,
    };
    fn targetOf(window: z.Window) Target {
        if (ui.Context.ofWindow(window)) |context| if (view.Host.ofContext(context)) |host| return .{ .host = host };
        if (comptime options.webview) if (webview.View.ofWindow(window)) |page| return .{ .page = page };
        return .other;
    }

    /// Runs `function` on the main thread with the window `id` resolved.
    fn withWindow(self: *Driver, arena: std.mem.Allocator, id: u64, failure: *Failure, state: anytype, comptime function: fn (@TypeOf(state), z.Window, u64) Error!void) Error!void {
        const Call = struct {
            driver: *Driver,
            arena: std.mem.Allocator,
            id: u64,
            failure: *Failure,
            state: @TypeOf(state),
            result: Error!void = {},
            fn run(call: *@This()) void {
                const window = call.driver.resolve(call.arena, call.id, call.failure) catch |err| {
                    call.result = err;
                    return;
                };
                const shown = call.driver.idOf(window) catch {
                    call.result = error.OutOfMemory;
                    return;
                };
                call.result = function(call.state, window, shown);
            }
        };
        var call: Call = .{ .driver = self, .arena = arena, .id = id, .failure = failure, .state = state };
        try self.onMain(&call, Call.run);
        return call.result;
    }

    fn windowsCall(context: *anyopaque, arena: std.mem.Allocator, failure: *Failure) Error![]const protocol.WindowInfo {
        const self: *Driver = @ptrCast(@alignCast(context));
        const State = struct {
            driver: *Driver,
            arena: std.mem.Allocator,
            failure: *Failure,
            list: std.ArrayList(protocol.WindowInfo) = .empty,
            /// Pages, whose URLs their scripts tell after the listing.
            pages: std.ArrayList(usize) = .empty,
            result: Error!void = {},
            fn run(state: *@This()) void {
                state.result = state.collect();
            }
            fn collect(state: *@This()) Error!void {
                var storage: [max_windows]z.Window = undefined;
                const open = state.driver.openWindows(&storage) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return fail(state.failure, state.arena, .failed, "the app has more than {d} windows", .{max_windows}),
                };
                for (open) |window| {
                    var title_storage: [1024]u8 = undefined;
                    const title = window.title(&title_storage) catch "";
                    const current = window.state() catch continue;
                    const client = window.clientBounds() catch z.ClientBounds{ .width = 0, .height = 0 };
                    const position = client.position orelse z.ScreenPoint{ .x = 0, .y = 0 };
                    const rect: protocol.Rect = .{ .x = @floatFromInt(position.x), .y = @floatFromInt(position.y), .width = @floatFromInt(client.width), .height = @floatFromInt(client.height) };
                    const target = targetOf(window);
                    if (target == .page) try state.pages.append(state.arena, state.list.items.len);
                    try state.list.append(state.arena, .{
                        .id = try state.driver.idOf(window),
                        .title = try state.arena.dupe(u8, title),
                        .kind = if (target == .page) "page" else "content",
                        .bounds = rect,
                        .contentBounds = rect,
                        .focused = current.focused,
                        .visible = current.visible and !current.minimized,
                    });
                }
            }
        };
        var state: State = .{ .driver = self, .arena = arena, .failure = failure };
        try self.onMain(&state, State.run);
        try state.result;
        for (state.pages.items) |at| {
            const info = &state.list.items[at];
            var ignored: Failure = .{};
            const value = self.evaluate(arena, info.id, "location.href", &ignored) catch |err| switch (err) {
                error.Quit, error.OutOfMemory => return err,
                error.Failed => continue,
            };
            const href = std.json.parseFromSliceLeaky([]const u8, arena, value, .{}) catch continue;
            info.url = href;
        }
        return state.list.items;
    }

    fn treeCall(context: *anyopaque, arena: std.mem.Allocator, id: u64, failure: *Failure) Error!protocol.Tree {
        const self: *Driver = @ptrCast(@alignCast(context));
        const State = struct {
            arena: std.mem.Allocator,
            failure: *Failure,
            /// The view was not laid out: the Host had a pass for an event
            /// since its last frame. The window is asked for a frame.
            unarranged: bool = false,
            /// Read the tree even so, once the wait for a frame is over.
            anyway: bool = false,
            tree: protocol.Tree = undefined,
            fn run(state: *@This(), window: z.Window, shown: u64) Error!void {
                const host = try hostOf(state.arena, window, shown, state.failure);
                if (!host.arranged and !state.anyway) {
                    state.unarranged = true;
                    window.invalidate();
                    return;
                }
                state.unarranged = false;
                state.tree = try tree.build(state.arena, shown, host);
            }
        };
        var state: State = .{ .arena = arena, .failure = failure };
        var waited: u64 = 0;
        while (true) {
            try self.withWindow(arena, id, failure, &state, State.run);
            if (!state.unarranged) return state.tree;
            if (waited >= layout_wait_ns) state.anyway = true else {
                zio.sleep(poll_ns);
                waited += poll_ns;
            }
        }
    }

    fn hostOf(arena: std.mem.Allocator, window: z.Window, shown: u64, failure: *Failure) Error!*view.Host {
        return switch (targetOf(window)) {
            .host => |host| host,
            .page => fail(failure, arena, .unsupported, "window {d} shows a web page: use eval", .{shown}),
            .other => fail(failure, arena, .unsupported, "window {d} shows no views", .{shown}),
        };
    }

    fn actCall(context: *anyopaque, arena: std.mem.Allocator, id: u64, request: protocol.Act, failure: *Failure) Error!void {
        const self: *Driver = @ptrCast(@alignCast(context));
        const action: view.Host.Action = switch (request.action) {
            .press => .press,
            .focus => .focus,
            .increment => .increment,
            .decrement => .decrement,
            .setValue => .{ .set_value = request.text },
            .insertText => .{ .insert_text = request.text },
            .expand => .expand,
            .collapse => .collapse,
            .selectText, .scrollIntoView => return fail(failure, arena, .unsupported, "views do not take {s} from automation", .{@tagName(request.action)}),
        };
        const State = struct {
            arena: std.mem.Allocator,
            failure: *Failure,
            request: protocol.Act,
            action: view.Host.Action,
            fn run(state: *@This(), window: z.Window, shown: u64) Error!void {
                const host = try hostOf(state.arena, window, shown, state.failure);
                const element = state.request.id;
                host.perform(element, state.action) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.NoElement => fail(state.failure, state.arena, .no_element, "window {d} shows no element {d}", .{ shown, element }),
                    error.NotSupported => fail(state.failure, state.arena, .unsupported, "element {d} cannot {s}", .{ element, @tagName(state.request.action) }),
                    error.InvalidValue => fail(state.failure, state.arena, .invalid_request, "element {d} takes a number, not \"{s}\"", .{ element, state.request.text }),
                    error.Disabled => fail(state.failure, state.arena, .failed, "element {d} is disabled", .{element}),
                    error.Hidden => fail(state.failure, state.arena, .failed, "element {d} is not shown", .{element}),
                    error.Inert => fail(state.failure, state.arena, .failed, "element {d} is behind a dialog", .{element}),
                    else => fail(state.failure, state.arena, .failed, "element {d}: {s}", .{ element, @errorName(err) }),
                };
            }
        };
        var state: State = .{ .arena = arena, .failure = failure, .request = request, .action = action };
        try self.withWindow(arena, id, failure, &state, State.run);
    }

    fn inputCall(context: *anyopaque, arena: std.mem.Allocator, id: u64, events: []const protocol.InputEvent, failure: *Failure) Error!void {
        const self: *Driver = @ptrCast(@alignCast(context));
        const State = struct {
            arena: std.mem.Allocator,
            failure: *Failure,
            events: []const protocol.InputEvent,
            fn run(state: *@This(), window: z.Window, shown: u64) Error!void {
                if (targetOf(window) == .page) return fail(state.failure, state.arena, .unsupported, "window {d} shows a web page: use eval", .{shown});
                for (state.events) |event| {
                    deliver(window, event) catch |err| return fail(state.failure, state.arena, .failed, "window {d}: {s}", .{ shown, @errorName(err) });
                }
            }
            fn deliver(window: z.Window, event: protocol.InputEvent) !void {
                switch (event) {
                    .pointer_move => |p| try window.emitEvent(.{ .pointer_move = .{ .x = p.x, .y = p.y } }),
                    .pointer_down => |p| try window.emitEvent(.{ .pointer_down = .{ .position = .{ .x = p.x, .y = p.y }, .button = p.button, .modifiers = p.modifiers } }),
                    .pointer_up => |p| try window.emitEvent(.{ .pointer_up = .{ .position = .{ .x = p.x, .y = p.y }, .button = p.button, .modifiers = p.modifiers } }),
                    .wheel => |w| try window.emitEvent(.{ .wheel = .{ .position = .{ .x = w.pointer.x, .y = w.pointer.y }, .delta = .{ .x = w.dx, .y = w.dy } } }),
                    .key_down => |key| _ = try window.emitKey(key, false),
                    .key_up => |key| _ = try window.emitKey(key, true),
                    .text => |text| try window.emitEvent(.{ .text_input = .{ .text = text, .producer = .application } }),
                }
            }
        };
        var state: State = .{ .arena = arena, .failure = failure, .events = events };
        try self.withWindow(arena, id, failure, &state, State.run);
    }

    fn menuCall(context: *anyopaque, arena: std.mem.Allocator, id: u64, path: []const []const u8, failure: *Failure) Error!void {
        const self: *Driver = @ptrCast(@alignCast(context));
        const State = struct {
            arena: std.mem.Allocator,
            failure: *Failure,
            path: []const []const u8,
            fn run(state: *@This(), window: z.Window, shown: u64) Error!void {
                window.activateMenuItem(state.path) catch |err| return switch (@as(anyerror, err)) {
                    error.NoMenu, error.UnsupportedCapability => fail(state.failure, state.arena, .unsupported, "window {d} shows no menu bar", .{shown}),
                    error.NoMenuItem => fail(state.failure, state.arena, .failed, "the menu has no item {s}", .{pathText(state.arena, state.path)}),
                    error.MenuItemDisabled => fail(state.failure, state.arena, .failed, "the menu item {s} is disabled", .{pathText(state.arena, state.path)}),
                    error.MenuItemIsSubmenu => fail(state.failure, state.arena, .failed, "the menu item {s} opens a submenu", .{pathText(state.arena, state.path)}),
                    else => fail(state.failure, state.arena, .failed, "window {d}: {s}", .{ shown, @errorName(err) }),
                };
            }
        };
        var state: State = .{ .arena = arena, .failure = failure, .path = path };
        try self.withWindow(arena, id, failure, &state, State.run);
    }

    fn pathText(arena: std.mem.Allocator, path: []const []const u8) []const u8 {
        return std.json.Stringify.valueAlloc(arena, path, .{}) catch "";
    }

    fn captureCall(context: *anyopaque, arena: std.mem.Allocator, id: u64, failure: *Failure) Error!protocol.Capture {
        const self: *Driver = @ptrCast(@alignCast(context));
        const State = struct {
            arena: std.mem.Allocator,
            failure: *Failure,
            image: z.Capture = undefined,
            fn run(state: *@This(), window: z.Window, shown: u64) Error!void {
                state.image = window.capture(state.arena) catch |err| switch (@as(anyerror, err)) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.UnsupportedCapability => return fail(state.failure, state.arena, .unsupported, "this platform cannot capture window {d}", .{shown}),
                    else => return fail(state.failure, state.arena, .failed, "window {d} could not be captured: {s}", .{ shown, @errorName(err) }),
                };
            }
        };
        var state: State = .{ .arena = arena, .failure = failure };
        try self.withWindow(arena, id, failure, &state, State.run);
        const encoded = try png.encode(arena, state.image.width, state.image.height, state.image.pixels);
        return .{ .png = encoded, .width = state.image.width, .height = state.image.height };
    }

    fn evalCall(context: *anyopaque, arena: std.mem.Allocator, id: u64, script: []const u8, failure: *Failure) Error![]const u8 {
        const self: *Driver = @ptrCast(@alignCast(context));
        return self.evaluate(arena, id, script, failure);
    }

    /// Evaluates `script` in the page of the window `id` and returns its
    /// value as JSON.
    const evaluate = if (options.webview) evaluatePage else evaluateNone;

    fn evaluateNone(self: *Driver, arena: std.mem.Allocator, id: u64, _: []const u8, failure: *Failure) Error![]const u8 {
        const State = struct {
            arena: std.mem.Allocator,
            failure: *Failure,
            fn run(state: *@This(), _: z.Window, shown: u64) Error!void {
                return fail(state.failure, state.arena, .unsupported, "window {d} shows native UI, not a web page: use tree", .{shown});
            }
        };
        var state: State = .{ .arena = arena, .failure = failure };
        try self.withWindow(arena, id, failure, &state, State.run);
        return fail(failure, arena, .unsupported, "this build has no web views", .{});
    }

    fn evaluatePage(self: *Driver, arena: std.mem.Allocator, id: u64, script: []const u8, failure: *Failure) Error![]const u8 {
        const State = struct {
            arena: std.mem.Allocator,
            failure: *Failure,
            script: []const u8,
            /// Set by the completion, which may come after the main-thread
            /// call returned; the connection's thread waits for it.
            done: zio.ResetEvent = .{},
            value: Error![]const u8 = "null",
            fn run(state: *@This(), window: z.Window, shown: u64) Error!void {
                const page = switch (targetOf(window)) {
                    .page => |page| page,
                    else => return fail(state.failure, state.arena, .unsupported, "window {d} shows native UI, not a web page: use tree", .{shown}),
                };
                _ = page.evaluateJS(state.script, .{ .timeout_ms = script_timeout_ms }, .{ .context = state, .complete = complete }) catch |err| {
                    return fail(state.failure, state.arena, .failed, "window {d}: {s}", .{ shown, @errorName(err) });
                };
            }
            fn complete(pointer: *anyopaque, result: webview.ScriptResult) void {
                const state: *@This() = @ptrCast(@alignCast(pointer));
                state.value = switch (result) {
                    .json => |json| state.arena.dupe(u8, json),
                    .timed_out => fail(state.failure, state.arena, .timeout, "the script ran longer than {d} ms", .{script_timeout_ms}),
                    else => |other| fail(state.failure, state.arena, .failed, "the script failed: {s}", .{@tagName(other)}),
                };
                state.done.set();
            }
        };
        var state: State = .{ .arena = arena, .failure = failure, .script = script };
        // A call that failed before it started the script leaves no
        // completion to wait for.
        try self.withWindow(arena, id, failure, &state, State.run);
        state.done.wait();
        return state.value;
    }

    fn idleCall(context: *anyopaque, arena: std.mem.Allocator, id: u64, timeout_ms: u64, failure: *Failure) Error!void {
        const self: *Driver = @ptrCast(@alignCast(context));
        const State = struct {
            pending: bool = false,
            page: bool = false,
            fn run(state: *@This(), window: z.Window, _: u64) Error!void {
                state.page = false;
                switch (targetOf(window)) {
                    .host => |host| state.pending = window.framePending() or (!host.arranged and host.context.window != null),
                    .page => |page| {
                        state.page = true;
                        state.pending = if (comptime options.webview) page.isLoading() else false;
                    },
                    .other => state.pending = window.framePending(),
                }
            }
        };
        var state: State = .{};
        var timer = zio.Timer.start() catch return fail(failure, arena, .failed, "no monotonic clock", .{});
        while (true) {
            try self.withWindow(arena, id, failure, &state, State.run);
            if (!state.pending and !state.page) return;
            // A page has settled once it loaded and answers a script.
            if (!state.pending) {
                if (self.evaluate(arena, id, "true", failure)) |_| return else |err| switch (err) {
                    error.Failed => if (!std.mem.endsWith(u8, failure.message, "PageLoading") and !std.mem.endsWith(u8, failure.message, "NotReady")) return err,
                    else => return err,
                }
                failure.* = .{};
            }
            if (timeout_ms != 0 and timer.read() >= timeout_ms * std.time.ns_per_ms) {
                return fail(failure, arena, .timeout, "window {d} still draws after {d} ms", .{ id, timeout_ms });
            }
            zio.sleep(poll_ns);
        }
    }
};
