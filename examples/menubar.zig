//! Native menus: a menu bar, a context menu, a tray icon and a message box.
//!
//! A `ziggurat_system.Owner` attached to the window installs a menu bar with
//! submenus, keyboard accelerators and a check item, opens a context menu on a
//! right-click in the content, and shows an asynchronous "About" message box.
//! A standalone `system.Tray` adds a notification-area icon whose own menu
//! shows or hides the window and quits. Every command lands in one `on_action`
//! callback on the main thread and is logged in the window.
//!
//! Run with `zig build run-menubar`. On Linux the tray needs a status-notifier
//! host on the session bus; without one the icon stays invisible.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const system = @import("ziggurat_system");

const Command = enum(u64) {
    file = 1,
    new,
    open,
    quit,
    view_menu,
    status_bar,
    zoom,
    zoom_in,
    zoom_out,
    zoom_reset,
    help,
    about,
    // Context and tray menu commands.
    copy_zoom,
    reset_all,
    show_window,
    hide_window,
    fn id(self: Command) u64 {
        return @backingInt(self);
    }
    fn label(id_value: u64) []const u8 {
        const value = std.enums.fromInt(Command, id_value) orelse return "unknown";
        return @tagName(value);
    }
};

const ctrl: system.Modifiers = .{ .control = true };
const context_request = 1;
const tray_request = 2;
const about_request = 3;

const Menus = struct {
    window: ?z.Window = null,
    owner: system.Owner = undefined,
    tray: system.Tray = undefined,
    tray_shown: bool = false,
    status_bar: bool = true,
    zoom: i32 = 100,
    documents: u32 = 0,
    log: [6][64]u8 = undefined,
    log_len: [6]usize = @splat(0),
    log_count: usize = 0,
    host: view.Host = undefined,
    /// The Host's own input routing, which every other event still reaches.
    host_input: ?*const fn (*anyopaque, *ui.Context, z.Event) bool = null,

    /// The menu bar snapshot; it is rebuilt whenever the check state changes.
    fn barItems(self: *const Menus) [16]system.Item {
        return .{
            .{ .id = Command.file.id(), .kind = .submenu, .label = "&File" },
            .{ .id = Command.new.id(), .parent = Command.file.id(), .label = "&New", .accelerator = .{ .key = .n, .modifiers = ctrl } },
            .{ .id = Command.open.id(), .parent = Command.file.id(), .label = "&Open...", .accelerator = .{ .key = .o, .modifiers = ctrl }, .enabled = false },
            .{ .parent = Command.file.id(), .kind = .separator },
            .{ .id = Command.quit.id(), .parent = Command.file.id(), .label = "&Quit", .accelerator = .{ .key = .q, .modifiers = ctrl } },
            .{ .id = Command.view_menu.id(), .kind = .submenu, .label = "&View" },
            .{ .id = Command.status_bar.id(), .parent = Command.view_menu.id(), .label = "&Status bar", .checked = self.status_bar, .accelerator = .{ .key = .b, .modifiers = ctrl } },
            .{ .id = Command.zoom.id(), .parent = Command.view_menu.id(), .kind = .submenu, .label = "&Zoom" },
            .{ .id = Command.zoom_in.id(), .parent = Command.zoom.id(), .label = "Zoom &in", .accelerator = .{ .key = .digit1, .modifiers = ctrl } },
            .{ .id = Command.zoom_out.id(), .parent = Command.zoom.id(), .label = "Zoom &out", .accelerator = .{ .key = .digit2, .modifiers = ctrl } },
            .{ .parent = Command.zoom.id(), .kind = .separator },
            .{ .id = Command.zoom_reset.id(), .parent = Command.zoom.id(), .label = "&Actual size", .accelerator = .{ .key = .digit0, .modifiers = ctrl } },
            .{ .id = Command.help.id(), .kind = .submenu, .label = "&Help" },
            .{ .id = Command.about.id(), .parent = Command.help.id(), .label = "&About", .accelerator = .{ .key = .f1 } },
            .{ .parent = Command.help.id(), .kind = .separator },
            .{ .id = Command.reset_all.id(), .parent = Command.help.id(), .label = "&Reset example" },
        };
    }
    const context_items = [_]system.Item{
        .{ .id = Command.zoom_in.id(), .label = "Zoom &in" },
        .{ .id = Command.zoom_out.id(), .label = "Zoom &out" },
        .{ .kind = .separator },
        .{ .id = Command.reset_all.id(), .label = "&Reset example" },
    };
    const tray_items = [_]system.Item{
        .{ .id = Command.show_window.id(), .label = "&Show window" },
        .{ .id = Command.hide_window.id(), .label = "&Hide window" },
        .{ .kind = .separator },
        .{ .id = Command.quit.id(), .label = "&Quit" },
    };

    fn note(self: *Menus, comptime format: []const u8, args: anytype) void {
        const slot = self.log_count % self.log.len;
        self.log_len[slot] = (std.fmt.bufPrint(&self.log[slot], format, args) catch @as([]const u8, &self.log[slot])).len;
        self.log_count += 1;
        if (self.window) |window| window.invalidate();
    }

    /// One handler for menu bar, accelerator, context menu, tray and dialog
    /// results. Runs on the main thread.
    fn run(self: *Menus, id: u64) void {
        self.note("command: {s}", .{Command.label(id)});
        const command = std.enums.fromInt(Command, id) orelse return;
        switch (command) {
            .new => self.documents += 1,
            .quit => _ = (self.window orelse return).app.requestQuit(),
            .status_bar => {
                self.status_bar = !self.status_bar;
                self.owner.setItemState(Command.status_bar.id(), true, self.status_bar) catch |err| self.note("setItemState: {s}", .{@errorName(err)});
            },
            .zoom_in => self.zoom = @min(self.zoom + 10, 300),
            .zoom_out => self.zoom = @max(self.zoom - 10, 30),
            .zoom_reset => self.zoom = 100,
            .about => self.owner.showMessage(about_request, .{
                .title = "About",
                .message = "Ziggurat menu example.\nMenus, accelerators, a context menu and a tray icon.",
                .buttons = &.{.{ .id = 1, .label = "OK" }},
                .default_button = 0,
                .cancel_button = 0,
            }) catch |err| self.note("showMessage: {s}", .{@errorName(err)}),
            .reset_all => {
                self.zoom = 100;
                self.documents = 0;
            },
            .show_window => if (self.window) |window| {
                window.show();
                window.perform(.focus) catch {};
            },
            .hide_window => if (self.window) |window| window.perform(.hide) catch {},
            else => {},
        }
        if (self.window) |window| window.invalidate();
    }

    fn onOwner(ptr: *anyopaque, _: z.Window, action: system.Action) void {
        const self: *Menus = @ptrCast(@alignCast(ptr));
        switch (action) {
            .menu => |id| self.run(id),
            .popup => |result| if (result.selected) |id| self.run(id) else self.note("context menu dismissed", .{}),
            .message => |result| self.note("about box closed: {s}", .{@tagName(result.response)}),
            else => {},
        }
    }
    fn onTray(ptr: *anyopaque, tray: *system.Tray, action: system.TrayAction) void {
        const self: *Menus = @ptrCast(@alignCast(ptr));
        switch (action) {
            .activate => {
                const window = self.window orelse return;
                const visible = if (window.state()) |s| s.visible else |_| false;
                self.run(if (visible) Command.hide_window.id() else Command.show_window.id());
            },
            // Hosts that cannot draw the item's own menu ask for one here.
            .context => tray.popupMenu(tray_request, &tray_items, .icon) catch |err| self.note("tray popup: {s}", .{@errorName(err)}),
            .menu => |id| self.run(id),
            .popup => |result| if (result.selected) |id| self.run(id),
        }
    }

    /// Wraps the Host's input route to open a context menu on a secondary
    /// press; every other event goes to the Host unchanged.
    fn onInput(ptr: *anyopaque, context: *ui.Context, event: z.Event) bool {
        const host: *view.Host = @ptrCast(@alignCast(ptr));
        const self: *Menus = @fieldParentPtr("host", host);
        if (event == .pointer_down and event.pointer_down.button == .secondary) {
            const at = event.pointer_down.position;
            self.owner.popupMenu(context_request, &context_items, .{ .client = .{ .x = at.x, .y = at.y } }) catch |err| self.note("popupMenu: {s}", .{@errorName(err)});
            return true;
        }
        return self.host_input.?(ptr, context, event);
    }

    fn build(self: *Menus, v: *view.View) anyerror!void {
        try v.text("Menus, accelerators and tray", .{ .font = view.Font.heading3 });
        try v.text("Use the menu bar or its shortcuts (Ctrl+N, Ctrl+B, Ctrl+1/2/0, F1, Ctrl+Q).", .{});
        try v.text("Right-click anywhere in this area for a context menu.", .{});
        try v.textf("Documents created: {d}", .{self.documents}, .{});
        try v.textf("Zoom: {d}%", .{self.zoom}, .{ .font = .{ .size = @floatFromInt(@divTrunc(16 * self.zoom, 100)) } });
        try v.row(.{ .gap = 8 });
        if (try v.button("About...", .{})) self.run(Command.about.id());
        if (try v.button("Hide to tray", .{ .enabled = self.tray_shown })) self.run(Command.hide_window.id());
        try v.end();
        try v.spacer(.{});
        if (self.status_bar) {
            try v.column(.{ .self_align = .stretch, .background = 0xeef1f4, .padding = view.Insets.all(8), .gap = 2 });
            try v.text("Recent actions", .{ .color = 0x536475 });
            const shown = @min(self.log_count, self.log.len);
            for (0..shown) |offset| {
                const slot = (self.log_count - 1 - offset) % self.log.len;
                try v.text(self.log[slot][0..self.log_len[slot]], .{ .key = self.log_count - offset });
            }
            try v.end();
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();

    var menus: Menus = .{};
    var storage: view.Storage(64, 2048) = .{};
    menus.host = view.Host.init(&menus, Menus.build, storage.buffers(), .{});
    menus.owner = system.Owner.init(&menus, Menus.onOwner);
    menus.tray = system.Tray.init(&menus, Menus.onTray);

    const window = try app.createWindow(.{ .title = "Ziggurat / Menus", .width = 640, .height = 440 });
    menus.window = window;
    try menus.host.attach(window);
    menus.host_input = menus.host.context.on_input;
    menus.host.context.on_input = Menus.onInput;

    try menus.owner.attach(window);
    const bar = menus.barItems();
    try menus.owner.setMenu(&bar);
    if (menus.tray.show(app, .{ .tooltip = "Ziggurat menus", .title = "Menus", .menu = &Menus.tray_items })) {
        menus.tray_shown = true;
    } else |err| menus.note("tray unavailable: {s}", .{@errorName(err)});

    window.show();
    try app.run();

    // The window is closed: the Owner already released its native menus.
    // Remove the tray explicitly (App stop would also remove it).
    menus.tray.remove() catch {};
    menus.owner.detach() catch {};
}

test "context menu commands update state" {
    var menus: Menus = .{};
    var storage: view.Storage(64, 2048) = .{};
    var h = view.Harness.init(&menus, Menus.build, storage.buffers(), .{});
    try h.render();
    menus.run(Command.zoom_in.id());
    menus.run(Command.new.id());
    try h.render();
    try std.testing.expectEqual(@as(i32, 110), menus.zoom);
    _ = try h.find(.{ .text = "Documents created: 1" });
    menus.run(Command.reset_all.id());
    try std.testing.expectEqual(@as(i32, 100), menus.zoom);
}
