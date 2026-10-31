const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const Watchdog = @import("watchdog.zig").Watchdog;

const linux = builtin.os.tag == .linux;
const document =
    \\<!doctype html><html><head><title>menu</title></head><body style="margin:0;font:16px sans-serif">
    \\<a id=l href="https://example.test/doc" style="position:absolute;left:0;top:0;width:200px;height:40px;display:block">Example link</a>
    \\<p id=t style="position:absolute;left:0;top:100px;margin:0">Some text</p>
    \\<script>window.menus=0;addEventListener('contextmenu',()=>window.menus++)</script>
    \\</body></html>
;

extern fn zcm_watch(window: *anyopaque) c_int;
extern fn zcm_right_click(window: *anyopaque, x: c_int, y: c_int) c_int;
extern fn zcm_menu_key(window: *anyopaque) c_int;
extern fn zcm_result(menus: *c_int, items: *c_int, open_link: *c_int, copy_link: *c_int, app_items: *c_int, activated: *c_int) void;
extern fn zwv_test_right_click(native: *anyopaque, x: i32, y: i32) i32;

/// A right click on a link: the handler is told the link and the engine's
/// items, leaves out Copy Link and adds an item of the app's, which Linux
/// chooses as a user would. Then the menu of a selection, which the handler
/// prevents. The page's own contextmenu event fires each time.
const Probe = struct {
    app: *z.App,
    window: z.Window,
    store: []const u8,
    view: web.View = undefined,
    step: enum { load, link, selection, counted, done } = .load,
    menus: u32 = 0,
    failure: ?anyerror = null,

    fn fail(self: *Probe, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("context menu step {s}: {s}\n", .{ @tagName(self.step), @errorName(err) });
        self.app.quit();
    }
    fn options(self: *Probe) web.Options {
        return .{ .html = document, .storage = if (linux) .ephemeral else .profile, .user_data_folder = if (linux) "" else self.store, .context_menu = .{ .handler = .{ .context = self, .open = open } }, .page_listener = .{ .context = self, .event = page } };
    }
    fn rightClick(self: *Probe, x: i32, y: i32) void {
        const ok = if (linux) zcm_right_click(self.window.nativeHandle().?, x, y) != 0 else zwv_test_right_click(self.view.native.?, x, y) >= 0;
        if (!ok) self.fail(error.RightClickFailed);
    }
    fn open(ptr: *anyopaque, _: *web.View, menu: *web.ContextMenu) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.menus += 1;
        switch (self.step) {
            .link => {
                const link = menu.target.link_uri orelse return self.fail(error.LinkMissing);
                if (!std.mem.eql(u8, link, "https://example.test/doc")) return self.fail(error.WrongLink);
                if (menu.target.link_text) |text| if (!std.mem.eql(u8, std.mem.trim(u8, text, " \n"), "Example link")) {
                    std.debug.print("link text {s}\n", .{text});
                    return self.fail(error.WrongLinkText);
                };
                var copy_link = false;
                for (menu.items) |item| {
                    if (std.mem.eql(u8, item.id, web.context_menu.ids.copy_link)) copy_link = true;
                    if (item.kind != .separator and item.label.len == 0) return self.fail(error.UnlabeledItem);
                }
                if (!copy_link) {
                    for (menu.items) |item| std.debug.print("item {s} \"{s}\"\n", .{ item.id, item.label });
                    return self.fail(error.CopyLinkMissing);
                }
                menu.remove(web.context_menu.ids.copy_link);
                menu.append(.separator) catch |err| return self.fail(err);
                menu.append(.{ .command = .{ .label = "Open in browser", .command = 7 } }) catch |err| return self.fail(err);
                // WebView2 draws the menu itself, out of a test's reach.
                if (!linux) self.app.post(.{ .context = self, .call = selectText }) catch |err| self.fail(err);
            },
            .selection => {
                const selection = menu.target.selection orelse return self.fail(error.SelectionMissing);
                if (!std.mem.eql(u8, selection, "Some text")) {
                    std.debug.print("selection \"{s}\"\n", .{selection});
                    return self.fail(error.WrongSelection);
                }
                menu.prevent();
                self.step = .counted;
                self.app.post(.{ .context = self, .call = count }) catch |err| self.fail(err);
            },
            else => self.fail(error.UnexpectedMenu),
        }
    }
    fn page(ptr: *anyopaque, view: *web.View, input: web.PageEvent) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (input) {
            .completed => |info| {
                if (!info.success) return self.fail(error.LoadFailed);
                if (self.step != .load) return;
                if (linux and zcm_watch(self.window.nativeHandle().?) == 0) return self.fail(error.ViewMissing);
                _ = view.evaluateJS("1", .{}, .{ .context = self, .complete = laidOut }) catch |err| self.fail(err);
            },
            .context_menu_command => |chosen| {
                if (chosen.command != 7 or self.step != .link) return self.fail(error.WrongCommand);
                if (linux) {
                    var menus: c_int = 0;
                    var items: c_int = 0;
                    var open_link: c_int = 0;
                    var copy_link: c_int = 0;
                    var app_items: c_int = 0;
                    var activated: c_int = 0;
                    zcm_result(&menus, &items, &open_link, &copy_link, &app_items, &activated);
                    if (menus != 1 or open_link == 0 or copy_link != 0 or app_items != 1 or activated != 1) {
                        std.debug.print("menu shown: menus {d} items {d} open {d} copy {d} app {d} activated {d}\n", .{ menus, items, open_link, copy_link, app_items, activated });
                        return self.fail(error.MenuNotChanged);
                    }
                }
                selectText(self);
            },
            else => {},
        }
    }
    fn event(ptr: *anyopaque, _: *web.View, input: web.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (input) {
            .failed, .process_failed => self.fail(error.NativePageFailed),
            else => {},
        }
    }
    fn laidOut(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json) return self.fail(error.ScriptFailed);
        self.step = .link;
        self.rightClick(20, 20);
    }
    fn selectText(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.step = .selection;
        _ = self.view.evaluateJS("getSelection().selectAllChildren(document.getElementById('t'));String(getSelection())", .{}, .{ .context = self, .complete = selected }) catch |err| self.fail(err);
    }
    fn selected(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "\"Some text\"")) return self.fail(error.SelectionFailed);
        if (linux) {
            if (zcm_menu_key(self.window.nativeHandle().?) == 0) self.fail(error.MenuKeyFailed);
        } else self.rightClick(30, 110);
    }
    fn count(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        _ = self.view.evaluateJS("window.menus", .{}, .{ .context = self, .complete = counted }) catch |err| self.fail(err);
    }
    fn counted(ptr: *anyopaque, result: web.ScriptResult) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (result != .json or !std.mem.eql(u8, result.json, "2")) {
            if (result == .json) std.debug.print("page heard {s} menus\n", .{result.json});
            return self.fail(error.PageEventMissing);
        }
        self.step = .done;
        self.app.quit();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const store = if (linux) try allocator.dupe(u8, "") else blk: {
        const local = try zio.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local);
        break :blk try std.fs.path.join(allocator, &.{ local, "Ziggurat", "ContextMenuSmoke" });
    };
    defer allocator.free(store);
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 320, .height = 200 });
    defer _ = window.destroy() catch {};
    var probe: Probe = .{ .app = app, .window = window, .store = store };
    probe.view = web.View.init(allocator, &probe, Probe.event);
    // Input reaches a page that is on the screen.
    window.show();
    try probe.view.attach(window, probe.options());
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (probe.failure) |err| return err;
    if (probe.step != .done) std.debug.print("expired {} step {s} menus {d}\n", .{ watchdog.expired, @tagName(probe.step), probe.menus });
    try std.testing.expect(!watchdog.expired and probe.step == .done and probe.menus == 2);
    std.debug.print("context menu: link target and items, Copy Link left out, the app's item chosen (Linux), selection menu prevented, page events kept\n", .{});
}
