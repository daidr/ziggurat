//! A tour of the desktop integration in one window: a menu bar with
//! accelerators and check items, a context menu, a tray icon, native
//! dialogs, a notification, a global shortcut, the clipboard and dark mode.
//!
//! A `ziggurat_system.Owner` attached to the window carries the menu bar,
//! the context menu, message boxes, file pickers, the notification and the
//! Ctrl+Shift+Space hotkey; a standalone `system.Tray` adds the tray icon.
//! The clipboard goes through a `clipboard.Board`, whose reads complete
//! asynchronously. A `system.desktop.Watch` follows the system's light or
//! dark preference, and a button overrides it. Every result is logged in
//! the window. Closing the window hides it while the tray icon is shown, so
//! the shortcut and the tray bring it back; Quit ends the app.
//!
//! Run it with `zig build run-native`. On Linux the tray needs a
//! status-notifier host on the session bus, and notifications need a
//! notification daemon.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const system = @import("ziggurat_system");
const clipboard = system.clipboard;
const desktop = system.desktop;

const Command = enum(u64) {
    file = 1,
    quit,
    demo,
    say_hi,
    always_on_top,
    small,
    large,
    // Buttons, the context menu and the tray.
    open_files,
    confirm,
    copy,
    paste,
    notify,
    toggle_dark,
    clear_log,
    show_window,
    time,

    fn id(self: Command) u64 {
        return @intFromEnum(self);
    }
};

const ctrl_shift: system.Modifiers = .{ .control = true, .shift = true };
const context_request = 1;
const confirm_request = 2;
const tray_request = 3;
const notification_id = 1;
const hotkey_id = 1;
const log_lines = 10;
const sizes = [_][2]u32{ .{ 720, 520 }, .{ 1000, 720 } };

const Tour = struct {
    window: ?z.Window = null,
    host: view.Host = undefined,
    /// The Host's own input routing, which every other event still reaches.
    host_input: ?*const fn (*anyopaque, *ui.Context, z.Event) bool = null,
    owner: system.Owner = undefined,
    tray: system.Tray = undefined,
    tray_shown: bool = false,
    board: clipboard.Board = undefined,
    paste_request: clipboard.Request = .{},
    paste_buffer: [256]u8 = undefined,
    preferences: desktop.Watch = undefined,
    dark: bool = false,
    always_on_top: bool = false,
    large: bool = false,
    /// A command chosen during a build pass, run as a posted task.
    pending: ?Command = null,
    picked_paths: [4096]u8 = undefined,
    log: [log_lines][96]u8 = undefined,
    log_len: [log_lines]usize = @splat(0),
    log_count: usize = 0,

    fn note(self: *Tour, comptime format: []const u8, args: anytype) void {
        const slot = self.log_count % log_lines;
        self.log_len[slot] = (std.fmt.bufPrint(&self.log[slot], format, args) catch &self.log[slot]).len;
        self.log_count += 1;
        if (self.window) |window| window.invalidate();
    }

    fn barItems(self: *const Tour) [8]system.Item {
        return .{
            .{ .id = Command.file.id(), .kind = .submenu, .label = "&File" },
            .{ .id = Command.quit.id(), .parent = Command.file.id(), .label = "&Quit", .accelerator = .{ .key = .q, .modifiers = .{ .control = true } } },
            .{ .id = Command.demo.id(), .kind = .submenu, .label = "&Demo" },
            .{ .id = Command.say_hi.id(), .parent = Command.demo.id(), .label = "Say &Hi", .accelerator = .{ .key = .h, .modifiers = ctrl_shift } },
            .{ .id = Command.always_on_top.id(), .parent = Command.demo.id(), .label = "Always on &Top", .checked = self.always_on_top },
            .{ .parent = Command.demo.id(), .kind = .separator },
            .{ .id = Command.small.id(), .parent = Command.demo.id(), .label = "&Small", .checked = !self.large },
            .{ .id = Command.large.id(), .parent = Command.demo.id(), .label = "&Large", .checked = self.large },
        };
    }
    const context_items = [_]system.Item{
        .{ .id = Command.copy.id(), .label = "&Copy" },
        .{ .id = Command.paste.id(), .label = "&Paste" },
        .{ .kind = .separator },
        .{ .id = Command.toggle_dark.id(), .label = "Toggle &dark mode" },
        .{ .id = Command.clear_log.id(), .label = "C&lear log" },
    };
    const tray_items = [_]system.Item{
        .{ .id = Command.show_window.id(), .label = "&Show Window" },
        .{ .id = Command.time.id(), .label = "What &time is it?" },
        .{ .kind = .separator },
        .{ .id = Command.quit.id(), .label = "&Quit" },
    };

    /// One handler for buttons, menus, accelerators, the tray and the hotkey.
    fn run(self: *Tour, command: Command) void {
        const window = self.window orelse return;
        switch (command) {
            .file, .demo => {},
            .quit => _ = window.app.requestQuit(),
            .say_hi => self.note("Hi from the menu!", .{}),
            .always_on_top => {
                window.setAlwaysOnTop(!self.always_on_top) catch |err| return self.note("always on top: {s}", .{@errorName(err)});
                self.always_on_top = !self.always_on_top;
                self.owner.setItemState(Command.always_on_top.id(), true, self.always_on_top) catch {};
            },
            .small, .large => {
                self.large = command == .large;
                const size = sizes[@intFromBool(self.large)];
                window.resize(size[0], size[1]) catch |err| self.note("resize: {s}", .{@errorName(err)});
                // The two items act as a radio group.
                self.owner.setItemState(Command.small.id(), true, !self.large) catch {};
                self.owner.setItemState(Command.large.id(), true, self.large) catch {};
            },
            .open_files => self.owner.openFiles(.{}, &self.picked_paths, self, picked) catch |err| self.note("open: {s}", .{@errorName(err)}),
            .confirm => self.owner.showMessage(confirm_request, .{
                .title = "Native",
                .message = "Do you like native dialogs?\nThis dialog is native.",
                .buttons = &.{ .{ .id = 1, .label = "Yes" }, .{ .id = 2, .label = "No" } },
                .default_button = 0,
                .cancel_button = 1,
                .kind = .question,
            }) catch |err| self.note("message: {s}", .{@errorName(err)}),
            .copy => {
                var text: [64]u8 = undefined;
                const now: u64 = @intCast(@max(0, std.time.timestamp()));
                const value = std.fmt.bufPrint(&text, "Copied from Ziggurat at {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ now / 3600 % 24, now / 60 % 60, now % 60 }) catch unreachable;
                self.board.write(&.{.{ .format = .{ .kind = .text }, .data = value }}) catch |err| return self.note("copy: {s}", .{@errorName(err)});
                self.note("copied", .{});
            },
            .paste => {
                self.paste_request.cancel();
                self.board.read(&self.paste_request, .{ .kind = .text }, &self.paste_buffer, self, pasted, .{}) catch |err| self.note("paste: {s}", .{@errorName(err)});
            },
            .notify => self.owner.showNotification(notification_id, .{ .title = "Hello", .body = "From Ziggurat" }) catch |err| self.note("notify: {s}", .{@errorName(err)}),
            .toggle_dark => self.applyTheme(!self.dark),
            .clear_log => self.log_count = 0,
            .show_window => {
                window.show();
                window.perform(.focus) catch {};
            },
            .time => {
                const now: u64 = @intCast(@max(0, std.time.timestamp()));
                self.note("It's {d:0>2}:{d:0>2} UTC", .{ now / 3600 % 24, now / 60 % 60 });
            },
        }
        window.invalidate();
    }

    /// Buttons fire inside a build pass; run their command as a posted task.
    fn queue(self: *Tour, command: Command) void {
        const window = self.window orelse return;
        self.pending = command;
        window.app.post(.{ .context = self, .call = runPending }) catch {};
    }

    fn runPending(ptr: *anyopaque) void {
        const self: *Tour = @ptrCast(@alignCast(ptr));
        const command = self.pending orelse return;
        self.pending = null;
        self.run(command);
    }

    fn applyTheme(self: *Tour, dark: bool) void {
        self.dark = dark;
        _ = self.host.context.setTheme(if (dark) ui.Theme.dark() else ui.Theme.light()) catch |err| self.note("theme: {s}", .{@errorName(err)});
    }

    fn build(self: *Tour, v: *view.View) anyerror!void {
        try v.text("Native integration", .{ .font = view.Font.heading3 });
        try v.text("Right-click anywhere for a context menu. Try the tray icon and Ctrl+Shift+Space.", .{});
        try v.row(.{ .gap = 8 });
        if (try v.button("Open files…", .{})) self.queue(.open_files);
        if (try v.button("Ask a question", .{})) self.queue(.confirm);
        if (try v.button("Copy text", .{})) self.queue(.copy);
        try v.end();
        try v.row(.{ .gap = 8 });
        if (try v.button("Paste text", .{})) self.queue(.paste);
        if (try v.button("Notify", .{})) self.queue(.notify);
        if (try v.button("Toggle dark mode", .{})) self.queue(.toggle_dark);
        try v.end();
        try v.column(.{ .grow = 1, .self_align = .stretch, .padding = view.Insets.all(12), .gap = 4, .radius = 8, .border = 0x8a96a3, .key = 1 });
        const shown = @min(self.log_count, log_lines);
        for (0..shown) |index| {
            const slot = (self.log_count - shown + index) % log_lines;
            try v.text(self.log[slot][0..self.log_len[slot]], .{ .key = self.log_count - shown + index + 1 });
        }
        try v.end();
    }

    fn picked(ptr: *anyopaque, _: z.Window, result: system.picker.Result) void {
        const self: *Tour = @ptrCast(@alignCast(ptr));
        switch (result) {
            .selected => |path| self.note("picked: {s}", .{path}),
            .selected_multiple => |paths| {
                self.note("picked {d} file(s)", .{paths.len});
                for (paths[0..@min(paths.len, 3)]) |path| self.note("  {s}", .{path});
            },
            .cancelled => self.note("picker cancelled", .{}),
            .failed => |failure| self.note("picker failed: {s}", .{@errorName(failure.err)}),
        }
    }

    fn pasted(ptr: *anyopaque, result: clipboard.Result) void {
        const self: *Tour = @ptrCast(@alignCast(ptr));
        switch (result) {
            .data => |bytes| self.note("clipboard: {s}", .{bytes[0..@min(bytes.len, 72)]}),
            .unavailable => self.note("clipboard has no text", .{}),
            .capacity_exceeded => |size| self.note("clipboard text is {d} bytes, too long to show", .{size}),
            .failed => |failure| self.note("paste failed: {s}", .{@errorName(failure.err)}),
            .formats => {},
        }
    }

    fn onOwner(ptr: *anyopaque, _: z.Window, action: system.Action) void {
        const self: *Tour = @ptrCast(@alignCast(ptr));
        switch (action) {
            .menu => |id| self.run(std.meta.intToEnum(Command, id) catch return),
            .popup => |result| if (result.selected) |id| self.run(std.meta.intToEnum(Command, id) catch return),
            .hotkey => {
                self.run(.show_window);
                self.note("global shortcut pressed", .{});
            },
            .message => |result| switch (result.response) {
                .button => |button| self.note("answer: {s}", .{if (button == 1) "yes" else "no"}),
                else => self.note("question dismissed", .{}),
            },
            .notification_activated => self.note("notification clicked", .{}),
            else => {},
        }
    }

    fn onTray(ptr: *anyopaque, tray: *system.Tray, action: system.TrayAction) void {
        const self: *Tour = @ptrCast(@alignCast(ptr));
        switch (action) {
            .activate => self.run(.show_window),
            // Hosts that cannot draw the item's own menu ask for one here.
            .context => tray.popupMenu(tray_request, &tray_items, .icon) catch |err| self.note("tray popup: {s}", .{@errorName(err)}),
            .menu => |id| self.run(std.meta.intToEnum(Command, id) catch return),
            .popup => |result| if (result.selected) |id| self.run(std.meta.intToEnum(Command, id) catch return),
        }
    }

    /// Opens the context menu on a secondary press; every other event goes
    /// to the Host unchanged.
    fn onInput(ptr: *anyopaque, context: *ui.Context, event: z.Event) bool {
        const host: *view.Host = @ptrCast(@alignCast(ptr));
        const self: *Tour = @fieldParentPtr("host", host);
        if (event == .pointer_down and event.pointer_down.button == .secondary) {
            const at = event.pointer_down.position;
            self.owner.popupMenu(context_request, &context_items, .{ .client = .{ .x = at.x, .y = at.y } }) catch |err| self.note("context menu: {s}", .{@errorName(err)});
            return true;
        }
        return self.host_input.?(ptr, context, event);
    }

    /// The system's light or dark preference changed.
    fn onDesktop(ptr: *anyopaque, change: desktop.Change) void {
        const self: *Tour = @ptrCast(@alignCast(ptr));
        if (!change.preferences) return;
        const window = self.window orelse return;
        const preferences = desktop.preferences(window.app) catch return;
        if (preferences.color_scheme == .unknown) return;
        self.applyTheme(preferences.color_scheme == .dark);
        self.note("appearance is now {s}", .{@tagName(preferences.color_scheme)});
    }

    /// Closing hides the window while the tray can bring it back.
    fn onClose(ptr: *anyopaque, window: z.Window, reason: z.CloseReason) z.CloseDecision {
        const self: *Tour = @ptrCast(@alignCast(ptr));
        if (reason != .user or !self.tray_shown) return .allow;
        window.perform(.hide) catch return .allow;
        return .cancel;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();

    // The Tour holds every native owner at a stable address.
    var tour: Tour = .{};
    var storage: view.Storage(64, 2048) = .{};
    tour.host = view.Host.init(&tour, Tour.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(24), .gap = 12 } });
    tour.owner = system.Owner.init(&tour, Tour.onOwner);
    tour.tray = system.Tray.init(&tour, Tour.onTray);
    tour.preferences = desktop.Watch.init(&tour, Tour.onDesktop);
    try tour.board.init(app, .{});
    defer tour.board.deinit();

    const window = try app.createWindow(.{ .title = "Native", .width = sizes[0][0], .height = sizes[0][1], .min_width = 480, .min_height = 360, .on_close = .{ .context = &tour, .request = Tour.onClose } });
    tour.window = window;
    try tour.host.attach(window);
    tour.host_input = tour.host.context.on_input;
    tour.host.context.on_input = Tour.onInput;
    try tour.owner.attach(window);
    const bar = tour.barItems();
    try tour.owner.setMenu(&bar);

    if (tour.tray.show(app, .{ .tooltip = "Ziggurat Native", .title = "Native", .menu = &Tour.tray_items })) {
        tour.tray_shown = true;
    } else |err| tour.note("tray unavailable: {s}", .{@errorName(err)});
    tour.owner.registerHotkey(hotkey_id, .{ .key = .space, .modifiers = ctrl_shift }) catch |err| tour.note("shortcut: {s}", .{@errorName(err)});
    if (desktop.preferences(app)) |preferences| {
        if (preferences.color_scheme == .dark) tour.applyTheme(true);
    } else |_| {}
    tour.preferences.start(app, .{ .preferences = true }) catch |err| tour.note("appearance changes: {s}", .{@errorName(err)});
    var monitors: [desktop.max_monitors]desktop.Monitor = undefined;
    if (desktop.monitors(app, &monitors)) |count| {
        for (monitors[0..count]) |monitor| if (monitor.primary) tour.note("primary display: {d}x{d} @{d}x", .{ monitor.bounds.width, monitor.bounds.height, monitor.scale });
    } else |err| tour.note("displays: {s}", .{@errorName(err)});

    window.show();
    try app.run();
    tour.preferences.stop();
    tour.tray.remove() catch {};
    tour.owner.detach() catch {};
}

test "the log keeps the latest lines in order" {
    var tour: Tour = .{};
    for (0..log_lines + 2) |index| tour.note("line {d}", .{index});
    var storage: view.Storage(64, 2048) = .{};
    var h = view.Harness.init(&tour, Tour.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 720, .height = 520 } });
    try h.render();
    _ = try h.find(.{ .text = "line 2" });
    _ = try h.find(.{ .text = "line 11" });
    try std.testing.expectError(error.NotFound, h.find(.{ .text = "line 1" }));
}
