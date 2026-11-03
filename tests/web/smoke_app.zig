//! The app the browser smoke test drives in headless Chromium: a counter,
//! and two pages of a router, whose location the URL's
//! fragment follows. The page reads the window's pixels and title. A
//! FAIL title reports what browsers got wrong at start: each
//! page is the single instance, the app never updates itself, and windows
//! keep no placement.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const system = @import("ziggurat_system");
const updater = @import("ziggurat_updater");
const placement = @import("ziggurat_window_placement");
const ui = @import("ziggurat_ui");

const menu_request = 1;
const menu_items = [_]system.Item{
    .{ .id = 1, .label = "&Add ten" },
    .{ .kind = .separator },
    .{ .id = 2, .label = "&Reset" },
};

fn startupFailure(window: z.Window) ?[:0]const u8 {
    var claim = system.instance.claim(.{ .id = "dev.ziggurat.browser-smoke" }) catch return "FAIL: single instance claim failed";
    switch (claim) {
        .primary => |*primary| primary.deinit(),
        .secondary => return "FAIL: single instance is secondary",
    }
    var feed = updater.FeedBackend.init(std.heap.wasm_allocator, window.app, .{
        .feed = "https://example.invalid/feed.json",
        .public_key = @splat(0),
        .identity = "dev.ziggurat.browser-smoke",
        .target = "web",
        .current_version = .{ .major = 1, .minor = 0, .patch = 0 },
        .install_root = "/",
    });
    defer feed.deinit();
    const backend = feed.backend();
    if (backend.enabled(backend.context)) return "FAIL: updates enabled";
    if (placement.refresh(window)) |_| return "FAIL: window placement available" else |err| if (err != error.UnsupportedCapability) return "FAIL: window placement error";
    return null;
}

const Smoke = struct {
    count: i64 = 0,
    history: [8]view.RouteEntry = undefined,
    router: view.Router = undefined,
    host: view.Host = undefined,
    host_input: ?*const fn (*anyopaque, *ui.Context, z.Event) bool = null,
    owner: system.Owner = undefined,

    fn build(self: *Smoke, v: *view.View) anyerror!void {
        try v.row(.{ .gap = 8, .alignment = .center });
        if (try v.button("Home", .{})) try self.router.push("/");
        if (try v.button("About", .{})) try self.router.push("/about");
        try v.end();
        const route = try v.route(&self.router, .{});
        if (route.match("/about")) {
            route.title("About");
            try v.text("About page", .{ .color = 0xa8530f });
        } else {
            route.title("Home");
            try v.textf("Count: {d}", .{self.count}, .{ .color = 0x276aa5 });
            if (try v.button("Add one", .{})) self.count += 1;
        }
        try v.end();
    }

    /// A secondary press opens the page's context menu; its choice shows in
    /// the title, which the page reads.
    fn onInput(ptr: *anyopaque, context: *ui.Context, event: z.Event) bool {
        const host: *view.Host = @ptrCast(@alignCast(ptr));
        const self: *Smoke = @fieldParentPtr("host", host);
        if (event == .pointer_down and event.pointer_down.button == .secondary) {
            const at = event.pointer_down.position;
            self.owner.popupMenu(menu_request, &menu_items, .{ .client = .{ .x = at.x, .y = at.y } }) catch {};
            return true;
        }
        return self.host_input.?(ptr, context, event);
    }

    fn onOwner(ptr: *anyopaque, window: z.Window, action: system.Action) void {
        const self: *Smoke = @ptrCast(@alignCast(ptr));
        if (action != .popup) return;
        const chosen = action.popup.selected orelse return;
        if (chosen == 1) self.count += 10 else self.count = 0;
        window.setTitle(if (chosen == 1) "Menu: Add ten" else "Menu: Reset") catch {};
        window.invalidate();
    }
};

pub fn main() !void {
    const allocator = std.heap.wasm_allocator;
    var smoke: Smoke = .{};
    smoke.router = try view.Router.init(&smoke.history, "/");
    var storage: view.Storage(64, 4096) = .{};
    smoke.host = view.Host.init(&smoke, Smoke.build, storage.buffers(), .{});
    smoke.owner = system.Owner.init(&smoke, Smoke.onOwner);
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Ziggurat smoke" });
    if (startupFailure(window)) |failure| try window.setTitle(failure);
    try smoke.host.attach(window);
    smoke.host_input = smoke.host.context.on_input;
    smoke.host.context.on_input = Smoke.onInput;
    try smoke.owner.attach(window);
    defer smoke.owner.detach() catch {};
    window.show();
    try app.run();
}
