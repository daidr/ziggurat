const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const ipc = @import("ziggurat_ipc");
const i18n = @import("ziggurat_i18n");
const runtime = @import("ziggurat_page_runtime");
const Counter = @import("counter_service").Service;
const Watchdog = @import("watchdog.zig").Watchdog;

const html = "<!doctype html><meta charset=utf-8><title>Page runtime</title><p>Find the needle, Needle and NEEDLE here.</p><script>" ++ @embedFile("page_runtime_page") ++ "</script>";
const unset = ipc.Session.init("00000000000000000000000000000000") catch unreachable;

/// The application's counter plugin: the counter service behind a Host endpoint.
const CounterPlugin = struct {
    const limits: ipc.Limits = .{};
    const Dispatcher = ipc.Dispatcher(Counter, Implementation, CounterPlugin, limits);
    const Implementation = struct {
        pub fn add(_: *@This(), _: *CounterPlugin, params: Counter.methods.add.Params) ipc.Reply(Counter, "add") {
            const sum = @addWithOverflow(params.a, params.b);
            if (sum[1] != 0) return .{ .failure = .{ .code = .overflow, .message = "Integer overflow" } };
            return .{ .result = sum[0] };
        }
        pub fn ping(_: *@This(), _: *CounterPlugin, _: void) ipc.Reply(Counter, "ping") {
            return .{ .result = .{ .ok = true } };
        }
        pub fn watch(_: *@This(), _: *CounterPlugin, _: Counter.methods.watch.Params) ipc.Reply(Counter, "watch") {
            return .{ .failure = .{ .code = .unavailable, .message = "Not streamed here" } };
        }
    };
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher = .init(unset),
    implementation: Implementation = .{},
    opens: usize = 0,
    calls: usize = 0,

    fn open(context: *anyopaque, _: *runtime.Host, session: ipc.Session) void {
        const self: *CounterPlugin = @ptrCast(@alignCast(context));
        var canceled: [limits.max_pending]ipc.Token = undefined;
        _ = self.dispatcher.router.reset(session, &canceled) catch unreachable;
        self.opens += 1;
    }
    fn receive(context: *anyopaque, host: *runtime.Host, bytes: []const u8) void {
        const self: *CounterPlugin = @ptrCast(@alignCast(context));
        var action = self.dispatcher.dispatch(self.allocator, &self.implementation, self, bytes) catch return;
        switch (action) {
            .reply => |*pending| {
                defer pending.deinit();
                const packet = pending.encode(&self.dispatcher.router, self.allocator) catch return;
                defer self.allocator.free(packet);
                self.calls += 1;
                host.send(packet) catch {};
            },
            else => {},
        }
    }
    fn close(context: *anyopaque, _: *runtime.Host) void {
        const self: *CounterPlugin = @ptrCast(@alignCast(context));
        var canceled: [limits.max_pending]ipc.Token = undefined;
        _ = self.dispatcher.router.close(&canceled) catch unreachable;
    }
    const vtable: runtime.Endpoint.VTable = .{ .open = open, .receive = receive, .close = close };
    fn plugin(self: *CounterPlugin) runtime.Plugin {
        return .{ .name = "counter", .endpoint = .{ .context = self, .vtable = &vtable } };
    }
};

/// A find, or a plain script whose JSON result is compared as text.
const Step = struct { text: []const u8 = "", options: runtime.find.Options = .{}, expected: ?runtime.find.Result = null, script: ?[]const u8 = null, json: []const u8 = "" };
const finds = [_]Step{
    .{ .text = "needle", .expected = .{ .matches = 3, .active = 1 } },
    .{ .text = "needle", .options = .{ .find_next = true }, .expected = .{ .matches = 3, .active = 2 } },
    .{ .text = "needle", .options = .{ .find_next = true, .backward = true }, .expected = .{ .matches = 3, .active = 1 } },
    .{ .text = "needle", .options = .{ .backward = true }, .expected = .{ .matches = 3, .active = 3 } },
    .{ .text = "Needle", .options = .{ .match_case = true }, .expected = .{ .matches = 1, .active = 1 } },
    .{ .text = "absent", .expected = .{ .matches = 0, .active = 0 } },
};
const marks = "document.querySelectorAll('mark[data-ziggurat-find]').length";
// The same finds again without the custom highlight registry, where matches
// are wrapped in marks and unwrapped by stop.
const steps = finds ++ [_]Step{
    .{ .script = runtime.find.stop_script, .json = "null" },
    .{ .script = "(()=>{if(typeof CSS!=='undefined'&&CSS.highlights)Object.defineProperty(CSS,'highlights',{value:undefined,configurable:true});return typeof CSS.highlights})()", .json = "\"undefined\"" },
} ++ finds ++ [_]Step{
    .{ .text = "needle", .expected = .{ .matches = 3, .active = 1 } },
    .{ .script = marks, .json = "3" },
    .{ .text = "needle", .options = .{ .find_next = true }, .expected = .{ .matches = 3, .active = 2 } },
    .{ .script = "document.querySelectorAll('mark[data-ziggurat-find=active]')[0].textContent", .json = "\"Needle\"" },
    .{ .script = runtime.find.stop_script, .json = "null" },
    .{ .script = marks, .json = "0" },
};

const State = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    window: z.Window = undefined,
    view: web.View = undefined,
    controls: runtime.WindowControls = undefined,
    host: runtime.Host = undefined,
    counter: CounterPlugin,
    step: usize = 0,
    found: bool = false,
    closing: bool = false,
    closed: bool = false,
    failure: ?anyerror = null,

    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("page runtime smoke: {s}\n", .{@errorName(err)});
        self.app.quit();
    }
    fn send(context: *anyopaque, bytes: []const u8) !void {
        const self: *State = @ptrCast(@alignCast(context));
        try self.view.post(bytes);
    }
    fn windowClosed(context: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.closed = true;
        self.host.detach();
    }
    fn event(context: *anyopaque, view: *web.View, value: web.Event) void {
        const self: *State = @ptrCast(@alignCast(context));
        switch (value) {
            .message => |text| {
                if (self.host.receive(text) == .handled) return;
                self.message(view, text) catch |err| self.fail(err);
            },
            .failed => self.fail(error.WebViewFailed),
            .process_failed => self.fail(error.ProcessFailed),
            else => {},
        }
    }
    fn message(self: *State, view: *web.View, text: []const u8) !void {
        if (std.mem.startsWith(u8, text, "pr-failed:")) {
            std.debug.print("{s}\n", .{text});
            return error.PageFailed;
        }
        if (std.mem.eql(u8, text, "pr-locale")) {
            if (!try self.host.setLocale(try i18n.Locale.parse("he"))) return error.LocaleNotDelivered;
        } else if (std.mem.eql(u8, text, "pr-drop")) {
            if (!try self.host.fileDrop(&.{ "/tmp/a b.txt", "/tmp/文件" }, 12, 34)) return error.DropNotDelivered;
        } else if (std.mem.eql(u8, text, "pr-find")) {
            try self.find(view);
        } else if (std.mem.eql(u8, text, "pr-close")) {
            if (!self.found) return error.CloseBeforeFind;
            self.closing = true;
        } else return error.UnexpectedMessage;
    }
    fn find(self: *State, view: *web.View) !void {
        const step = steps[self.step];
        const script = if (step.script) |text| try self.allocator.dupe(u8, text) else try runtime.find.script(self.allocator, step.text, step.options);
        defer self.allocator.free(script);
        _ = try view.evaluateJS(script, .{ .timeout_ms = 5000 }, .{ .context = self, .complete = findDone });
    }
    fn findDone(context: *anyopaque, result: web.ScriptResult) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.checkFound(result) catch |err| self.fail(err);
    }
    fn checkFound(self: *State, result: web.ScriptResult) !void {
        const json = switch (result) {
            .json => |text| text,
            else => return error.FindEvaluationFailed,
        };
        const step = steps[self.step];
        if (step.script != null) {
            if (!std.mem.eql(u8, json, step.json)) {
                std.debug.print("script step {d}: expected {s}, found {s}\n", .{ self.step, step.json, json });
                return error.WrongScriptResult;
            }
        } else if (step.expected) |expected| {
            const actual = try runtime.find.parseResult(self.allocator, json);
            if (actual.matches != expected.matches or actual.active != expected.active) {
                std.debug.print("find step {d}: expected {any}, found {any}\n", .{ self.step, expected, actual });
                return error.WrongFindResult;
            }
        }
        self.step += 1;
        if (self.step < steps.len) return self.find(&self.view);
        self.found = true;
        try self.view.post("pr-host:found");
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .allocator = allocator, .app = app, .counter = .{ .allocator = allocator } };
    state.window = try app.createWindow(.{ .title = "Page runtime smoke", .on_closed = .{ .context = &state, .notify = State.windowClosed } });
    state.controls = .{ .window = state.window };
    state.host = .init(allocator, .{
        .transport = .{ .context = &state, .send = State.send },
        .controls = state.controls.controls(),
        .window_id = 7,
        .preferences = .{ .accent = 0x0a84ff, .color_scheme = .dark },
    });
    try state.host.use(state.counter.plugin());
    state.view = web.View.init(allocator, &state, State.event);

    var profile: []u8 = &.{};
    defer allocator.free(profile);
    if (builtin.os.tag == .windows) {
        const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "PageRuntimeSmoke" });
        try state.view.attach(state.window, .{ .html = html, .user_data_folder = profile });
    } else {
        try state.view.attach(state.window, .{ .html = html, .storage = .ephemeral });
    }
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    state.host.detach();
    try std.testing.expect(!watchdog.expired);
    if (state.failure) |err| return err;
    try std.testing.expect(state.found and state.closing and state.closed);
    try std.testing.expectEqual(1, state.counter.opens);
    try std.testing.expectEqual(1, state.counter.calls);
    try std.testing.expectEqual(null, state.host.last_error);
    std.debug.print("page runtime WebView smoke passed: handshake, window controls, locale/drop events, plugin session, find highlights x{d}, reply before close\n", .{steps.len});
}
