const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;

const linux = builtin.os.tag == .linux;
/// macOS pages are trusted HTML only, without a site to load scripts from:
/// the check there is the hidden element and the audio state.
const macos = builtin.os.tag == .macos;
const document =
    \\<!doctype html><title>page</title>
    \\<div class="banner" id="banner">ad</div><div id="text">text</div>
    \\<script src="/app.js"></script><script src="/ads/ad.js"></script>
    \\<script>document.title='loaded'</script>
;
const site_resources = [_]web.Resource{
    .{ .path = "/app.js", .mime = "text/javascript", .bytes = "window.appLoaded=true" },
    .{ .path = "/ads/ad.js", .mime = "text/javascript", .bytes = "window.adLoaded=true" },
};
const registrations = [_]web.SchemeRegistration{.{ .name = "asset", .treat_as_secure = true }};
const rules_source =
    \\[{"trigger":{"url-filter":"/ads/","resource-type":["script"]},"action":{"type":"block"}},
    \\ {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".banner"}}]
;
const state_script =
    \\[!!window.appLoaded,!!window.adLoaded,getComputedStyle(document.getElementById('banner')).display,getComputedStyle(document.getElementById('text')).display,document.title].join(' ')
;

/// Compiles rules, applies them from a page's first load, checks that the
/// ad script stayed unloaded and the banner hidden, then removes them and
/// reloads. The page starts muted, and stays muted until unmuted.
const Probe = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    window: z.Window,
    store: []const u8,
    view: web.View = undefined,
    rules: ?*web.ContentRules = null,
    applied: [1]*web.ContentRules = undefined,
    step: enum { compile, compile_again, compile_invalid, compile_empty, with_rules, without_rules, done } = .compile,
    loads: u32 = 0,
    failure: ?anyerror = null,

    fn fail(self: *Probe, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("content rules step {s}: {s}\n", .{ @tagName(self.step), @errorName(err) });
        self.app.quit();
    }
    fn compile(self: *Probe, id: []const u8, source: []const u8) void {
        _ = web.ContentRules.compile(self.allocator, self.app, id, source, .{ .store_directory = self.store }, .{ .context = self, .complete = compiled }) catch |err| self.fail(err);
    }
    fn compiled(ptr: *anyopaque, result: web.ContentRules.Result) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (self.step) {
            .compile, .compile_again => {
                if (result != .compiled) {
                    std.debug.print("result {s}\n", .{@tagName(result)});
                    return self.fail(error.CompileFailed);
                }
                if (!std.mem.eql(u8, result.compiled.id(), "smoke")) return self.fail(error.WrongId);
                if (self.rules) |previous| previous.release();
                self.rules = result.compiled;
                if (self.step == .compile) {
                    self.step = .compile_again;
                    return self.compile("smoke", rules_source);
                }
                self.step = .compile_invalid;
                // The engine takes no alternatives.
                self.compile("smoke-bad", "[{\"trigger\":{\"url-filter\":\"a|b\"},\"action\":{\"type\":\"block\"}}]");
            },
            .compile_invalid, .compile_empty => {
                if (result != .invalid) {
                    if (result == .compiled) result.compiled.release();
                    return self.fail(error.InvalidRulesCompiled);
                }
                if (self.step == .compile_invalid) {
                    self.step = .compile_empty;
                    return self.compile("smoke-bad", "[]");
                }
                self.step = .with_rules;
                self.applied = .{self.rules.?};
                self.view.attach(self.window, self.options()) catch |err| self.fail(err);
                // Options hold their own references.
                self.rules.?.release();
                self.rules = null;
                self.view.setAudioMuted(true) catch |err| return self.fail(err);
            },
            else => self.fail(error.UnexpectedCompletion),
        }
    }
    fn options(self: *Probe) web.Options {
        return .{
            .html = document,
            .storage = if (linux or macos) .ephemeral else .profile,
            .user_data_folder = if (linux or macos) "" else self.store,
            .custom_schemes = if (linux) &registrations else &.{},
            .local = if (macos) null else .{ .scheme = if (linux) "asset" else "https", .resources = &site_resources },
            .content_rules = &self.applied,
            .audio_muted = true,
            .page_listener = .{ .context = self, .event = page },
        };
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (input) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, input: web.PageEvent) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (input != .completed) return;
        if (!input.completed.success) return self.fail(error.LoadFailed);
        self.loads += 1;
        _ = view.evaluateJS(state_script, .{}, .{ .context = self, .complete = checked }) catch |err| self.fail(err);
    }
    fn checked(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.fail(error.ScriptFailed);
        const want = switch (self.step) {
            .with_rules => if (macos) "\"false false none block loaded\"" else "\"true false none block loaded\"",
            .without_rules => if (macos) "\"false false block block loaded\"" else "\"true true block block loaded\"",
            else => return self.fail(error.UnexpectedScript),
        };
        if (!std.mem.eql(u8, result.json, want)) {
            std.debug.print("page state {s}, want {s}\n", .{ result.json, want });
            return self.fail(error.WrongPageState);
        }
        const muted = self.view.audioMuted() catch |err| return self.fail(err);
        const audible = self.view.isAudible() catch |err| return self.fail(err);
        if (audible) return self.fail(error.SilentPageAudible);
        if (self.step == .with_rules) {
            if (!muted) return self.fail(error.MuteLost);
            self.step = .without_rules;
            self.view.setContentRules(&.{}) catch |err| return self.fail(err);
            self.view.setAudioMuted(false) catch |err| return self.fail(err);
            self.view.refresh() catch |err| return self.fail(err);
            return;
        }
        if (muted) return self.fail(error.UnmuteLost);
        self.step = .done;
        self.app.quit();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    if (!web.backendCapabilities().page_lifecycle) return error.SkipZigTest;
    var private = zio.tmpDir(.{});
    defer private.cleanup();
    const store = try zio.realPathAlloc(private.dir, ".", allocator);
    defer allocator.free(store);
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 320, .height = 240 });
    defer _ = window.destroy() catch {};
    var probe: Probe = .{ .allocator = allocator, .app = app, .window = window, .store = store };
    probe.view = web.View.init(allocator, &probe, Probe.event);
    defer if (probe.rules) |rules| rules.release();
    try std.testing.expectError(error.InvalidContentRulesId, web.ContentRules.compile(allocator, app, "bad id", "[]", .{ .store_directory = store }, .{ .context = &probe, .complete = Probe.compiled }));
    probe.compile("smoke", rules_source);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (probe.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and probe.step == .done and probe.loads == 2);
    std.debug.print("content rules: blocked a script and hid an element from the first load, removed and reloaded; muted from the start\n", .{});
}
