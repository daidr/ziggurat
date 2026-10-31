//! A keyboard launcher: a global shortcut (Ctrl+Alt+Space) shows and
//! focuses the window from anywhere, the search field filters a result list,
//! Up/Down move the selection, Enter runs it and Escape hides the window.
//!
//! Shortcuts come from a `ziggurat_system.Owner` on the window. Opening a
//! URL or folder is a blocking shell call, so each launch runs on one thread
//! the app starts itself; the result returns through `App.post`. Global
//! shortcuts need Windows or an X11 session; elsewhere the window stays
//! visible and Escape minimizes it instead.
//!
//! Run with `zig build run-launcher`.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const text = @import("ziggurat_view_text");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const system = @import("ziggurat_system");

const Command = union(enum) { url: []const u8, home, working_folder, web_search, about, quit };
const Entry = struct { title: []const u8, detail: []const u8, command: Command };
const entries = [_]Entry{
    .{ .title = "Open home folder", .detail = "File manager", .command = .home },
    .{ .title = "Open working folder", .detail = "File manager", .command = .working_folder },
    .{ .title = "Zig website", .detail = "https://ziglang.org", .command = .{ .url = "https://ziglang.org" } },
    .{ .title = "Zig standard library reference", .detail = "Browser", .command = .{ .url = "https://ziglang.org/documentation/master/std/" } },
    .{ .title = "Write an email", .detail = "Mail client", .command = .{ .url = "mailto:" } },
    .{ .title = "About this launcher", .detail = "Shows a message here", .command = .about },
    .{ .title = "Quit launcher", .detail = "Ends the app", .command = .quit },
};
const hotkey_id = 1;
const hotkey: system.Hotkey = .{ .key = .space, .modifiers = .{ .control = true, .alt = true } };

const Launcher = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    host: view.Host,
    owner: system.Owner,
    window: ?z.Window = null,
    document: *d.Document = undefined,
    editor: *editing.Field = undefined,
    search: text.TextField = undefined,
    /// The Host's own input routing, which runs before ours.
    host_input: ?*const fn (*anyopaque, *ui.Context, z.Event) bool = null,
    hotkey_error: ?anyerror = null,
    focus_pending: bool = true,
    /// Positions into `entries` of the current matches; `entries.len` is the
    /// web search for the query. Rebuilt by every build pass.
    matches: [entries.len + 1]usize = undefined,
    match_count: usize = 0,
    selected: usize = 0,
    scroll_model: ui.scroll.ScrollModel = .{},
    status: [256]u8 = undefined,
    status_len: usize = 0,
    /// One launch at a time, on a thread this app owns and joins.
    thread: ?std.Thread = null,
    target: [2048]u8 = undefined,
    target_len: usize = 0,
    target_is_url: bool = false,
    outcome: ?anyerror = null,

    fn query(self: *Launcher, buffer: []u8) []const u8 {
        const length = self.document.byteLength() catch return "";
        const count = self.document.read(.{ .start = 0, .end = @min(length, buffer.len) }, buffer) catch return "";
        return std.mem.trim(u8, buffer[0..count], " ");
    }
    fn setStatus(self: *Launcher, comptime format: []const u8, arguments: anytype) void {
        self.status_len = (std.fmt.bufPrint(&self.status, format, arguments) catch @as([]const u8, self.status[0..0])).len;
    }

    fn build(self: *Launcher, v: *view.View) anyerror!void {
        if (self.focus_pending and self.search.attached) {
            self.focus_pending = false;
            self.app.post(.{ .context = self, .call = focusSearch }) catch {};
        }
        var buffer: [256]u8 = undefined;
        const current = self.query(&buffer);
        self.match_count = 0;
        for (entries, 0..) |entry, index| if (std.ascii.findIgnoreCase(entry.title, current) != null) {
            self.matches[self.match_count] = index;
            self.match_count += 1;
        };
        if (current.len > 0) {
            self.matches[self.match_count] = entries.len;
            self.match_count += 1;
        }
        self.selected = @min(self.selected, self.match_count -| 1);

        try v.search(.{ .name = "Search commands", .self_align = .stretch });
        try v.embed(self.search.embed(), .{ .grow = 1, .key = 1 });
        try v.end();
        try v.scroll(&self.scroll_model, .{ .grow = 1, .self_align = .stretch, .key = 2 });
        try v.listBox(.{ .name = "Results", .self_align = .stretch });
        for (self.matches[0..self.match_count], 0..) |entry, position| {
            var label: [320]u8 = undefined;
            const title = if (entry == entries.len)
                try std.fmt.bufPrint(&label, "Search the web for \u{201c}{s}\u{201d}", .{current})
            else
                try std.fmt.bufPrint(&label, "{s}  \u{2014}  {s}", .{ entries[entry].title, entries[entry].detail });
            _ = try v.listItem(usize, &self.selected, position, title, .{ .key = entry + 1 });
        }
        try v.end();
        if (self.match_count == 0) try v.text("No matches", .{ .color = 0x536475 });
        try v.end();
        try v.row(.{ .gap = 8, .alignment = .center, .self_align = .stretch, .key = 3 });
        if (try v.button("Run", .{ .enabled = self.match_count > 0 and self.thread == null })) self.run();
        try v.text(self.status[0..self.status_len], .{ .grow = 1, .color = 0x536475 });
        try v.end();
        if (self.hotkey_error) |err| {
            try v.textf("Global shortcut unavailable ({s}); Escape minimizes.", .{@errorName(err)}, .{ .color = 0xa24c00, .key = 4 });
        } else try v.text("Ctrl+Alt+Space shows this window from anywhere; Escape hides it.", .{ .color = 0x536475, .key = 4 });
    }

    /// Run the selected match: built-in commands act here, URLs and folders
    /// go to the launch thread.
    fn run(self: *Launcher) void {
        if (self.match_count == 0 or self.thread != null) return;
        var buffer: [256]u8 = undefined;
        const current = self.query(&buffer);
        const entry = self.matches[self.selected];
        const command: Command = if (entry == entries.len) .web_search else entries[entry].command;
        var writer: std.Io.Writer = .fixed(&self.target);
        switch (command) {
            .about => return self.setStatus("A ziggurat_system and ziggurat_view example.", .{}),
            .quit => {
                _ = self.app.requestQuit();
                return;
            },
            .url => |url| writer.writeAll(url) catch return,
            .web_search => {
                writer.writeAll("https://duckduckgo.com/?q=") catch return;
                for (current) |byte| switch (byte) {
                    'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => writer.writeByte(byte) catch return,
                    else => writer.print("%{X:0>2}", .{byte}) catch return,
                };
            },
            .home => {
                const home = zio.getEnvVarOwned(self.allocator, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") catch return self.setStatus("No home folder is set.", .{});
                defer self.allocator.free(home);
                writer.writeAll(home) catch return;
            },
            .working_folder => {
                const path = zio.realpath(std.Io.Dir.cwd(), ".", &self.target) catch return self.setStatus("The working folder is unavailable.", .{});
                writer.end = path.len;
            },
        }
        self.target_len = writer.end;
        self.target_is_url = command == .url or command == .web_search;
        self.outcome = null;
        self.thread = std.Thread.spawn(.{}, launch, .{ self, std.Thread.getCurrentId() }) catch |err| {
            return self.setStatus("Could not start: {s}", .{@errorName(err)});
        };
        self.setStatus("Opening\u{2026}", .{});
    }

    /// The launch thread: one blocking shell request, then a post back. The
    /// post is its last action, so joining it on the main thread is brief.
    fn launch(self: *Launcher, main_thread: std.Thread.Id) void {
        const target = self.target[0..self.target_len];
        if (system.shell.Worker.init(main_thread)) |worker_value| {
            var worker = worker_value;
            self.outcome = if (self.target_is_url) (if (worker.openUrl(target, .{})) |_| null else |err| err) else (if (worker.openPath(target, .{})) |_| null else |err| err);
            worker.deinit();
        } else |err| self.outcome = err;
        // Closed means the app is stopping; main() joins this thread then.
        self.app.post(.{ .context = self, .call = launched }) catch {};
    }
    fn launched(ptr: *anyopaque) void {
        const self: *Launcher = @ptrCast(@alignCast(ptr));
        if (self.thread) |thread| thread.join();
        self.thread = null;
        const target = self.target[0..@min(self.target_len, 120)];
        if (self.outcome) |err| self.setStatus("Failed ({s}): {s}", .{ @errorName(err), target }) else self.setStatus("Opened {s}", .{target});
        if (self.window) |window| window.invalidate();
    }

    fn focusSearch(ptr: *anyopaque) void {
        const self: *Launcher = @ptrCast(@alignCast(ptr));
        self.editor.focus() catch {};
    }
    fn clearSearch(ptr: *anyopaque) void {
        const self: *Launcher = @ptrCast(@alignCast(ptr));
        _ = self.editor.setValue("") catch {};
    }
    fn hide(self: *Launcher) void {
        const window = self.window orelse return;
        // Clearing edits the field, so it waits until this input returns.
        self.app.post(.{ .context = self, .call = clearSearch }) catch {};
        self.selected = 0;
        window.perform(if (self.hotkey_error == null) .hide else .minimize) catch {};
    }

    fn onSystem(ptr: *anyopaque, window: z.Window, action: system.Action) void {
        const self: *Launcher = @ptrCast(@alignCast(ptr));
        if (action != .hotkey or action.hotkey != hotkey_id) return;
        const state = window.state() catch return;
        if (state.visible and state.focused and !state.minimized) return self.hide();
        window.perform(if (state.minimized) .restore else .show) catch {};
        window.perform(.focus) catch {};
        focusSearch(self);
    }
    fn onSubmit(context: ?*anyopaque, _: z.Window) void {
        const self: *Launcher = @ptrCast(@alignCast(context.?));
        self.run();
    }
    /// Up, Down and Escape belong to the launcher even while the search
    /// field has focus; everything else keeps the Host's routing.
    fn onInput(ptr: *anyopaque, context: *ui.Context, event: z.Event) bool {
        const host: *view.Host = @ptrCast(@alignCast(ptr));
        const self: *Launcher = @fieldParentPtr("host", host);
        if (self.host_input) |inner| if (inner(ptr, context, event)) return true;
        if (event != .key_input) return false;
        const key = event.key_input;
        // Leave keys to an input method that is composing.
        if (self.document.composition() catch null) |_| return false;
        switch (key.key) {
            .escape => self.hide(),
            .up => self.selected -|= 1,
            .down => self.selected = @min(self.selected + 1, self.match_count -| 1),
            else => return false,
        }
        if (self.window) |window| window.invalidate();
        return true;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch |err| std.log.err("engine close: {s}", .{@errorName(err)});
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "", .{});
    defer document.close() catch |err| std.log.err("document close: {s}", .{@errorName(err)});

    var launcher: Launcher = .{ .allocator = allocator, .app = app, .host = undefined, .owner = undefined, .document = document };
    var storage: view.Storage(64, 4096) = .{};
    launcher.host = view.Host.init(&launcher, Launcher.build, storage.buffers(), .{});
    launcher.owner = system.Owner.init(&launcher, Launcher.onSystem);
    // Stop and join the launch thread before the App goes away.
    defer if (launcher.thread) |thread| thread.join();

    const window = try app.createWindow(.{ .title = "Launcher", .width = 560, .height = 400, .min_width = 360, .min_height = 240 });
    launcher.window = window;
    try launcher.host.attach(window);
    launcher.host_input = launcher.host.context.on_input;
    launcher.host.context.on_input = Launcher.onInput;
    try launcher.host.context.prepareTextFields(allocator, .{});
    try launcher.owner.attach(window);
    launcher.owner.registerHotkey(hotkey_id, hotkey) catch |err| {
        launcher.hotkey_error = err;
    };

    launcher.editor = try editing.Field.create(allocator, document, engine, .{ .value_bytes = 256, .context = &launcher, .submit = Launcher.onSubmit });
    defer launcher.editor.close() catch |err| std.log.err("field close: {s}", .{@errorName(err)});
    launcher.search = text.TextField.init(launcher.editor, &launcher.host, .{ .font = .{ .size = 18 }, .scale = (try window.contentSize()).scale }, .{ .name = "Search" });
    defer launcher.search.detach();

    window.show();
    try app.run();
    launcher.window = null;
}
