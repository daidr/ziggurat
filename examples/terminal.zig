//! A terminal app: the user's shell in a window, emulated by
//! `ziggurat_terminal` and shown by its view leaf. The window takes the
//! shell's title and closes when the shell exits. Copy and paste use the
//! system clipboard where it can be read synchronously (Windows); elsewhere
//! the terminal keeps working without them.
//!
//! Run it with `zig build run-terminal`.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const system = @import("ziggurat_system");
const term = @import("ziggurat_terminal");
const terminal_view = @import("ziggurat_terminal_view");

const Shell = struct {
    window: ?z.Window = null,
    terminal: *terminal_view.TerminalView = undefined,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    /// The shell ended; the window closes after it.
    exited: bool = false,

    fn build(self: *Shell, v: *view.View) anyerror!void {
        try v.embed(self.terminal.embed(), .{ .grow = 1, .self_align = .stretch, .key = 1 });
    }

    /// Notices of the terminal, on the main thread.
    fn notice(context: ?*anyopaque, event: terminal_view.Notice) void {
        const self: *Shell = @ptrCast(@alignCast(context.?));
        switch (event) {
            .title => |title| {
                self.title_len = @min(title.len, self.title.len);
                @memcpy(self.title[0..self.title_len], title[0..self.title_len]);
                if (self.window) |window| window.setTitle(if (self.title_len > 0) self.title[0..self.title_len] else "Terminal") catch {};
            },
            .exited => {
                self.exited = true;
                // The notice arrives from a posted task: closing here is a request
                // the window handles at its own safe point.
                if (self.window) |window| _ = window.requestClose() catch {};
            },
            // Opening Ctrl+clicked links needs a `system.shell.Worker` thread,
            // which this example leaves out.
            .open, .bell, .directory => {},
        }
    }

    fn readClipboard(context: ?*anyopaque, buffer: []u8) anyerror!usize {
        const self: *Shell = @ptrCast(@alignCast(context.?));
        return system.clipboard.readText(self.window orelse return error.Closed, buffer);
    }

    fn writeClipboard(context: ?*anyopaque, text: []const u8) anyerror!void {
        const self: *Shell = @ptrCast(@alignCast(context.?));
        return system.clipboard.writeText(self.window orelse return error.Closed, text);
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // The state, terminal, view leaf and Host stay at stable addresses
    // while the window shows them.
    var shell: Shell = .{};
    var storage: view.Storage(8, 256) = .{};
    var host = view.Host.init(&shell, Shell.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(allocator, .{ .screen = .{ .scrollback = 5000 } });
    defer terminal.deinit();
    var leaf = terminal_view.TerminalView.init(&host, allocator, &terminal, .{
        .clipboard = .{ .context = &shell, .read = Shell.readClipboard, .write = Shell.writeClipboard },
        .notify = .{ .context = &shell, .call = Shell.notice },
    });
    leaf.bind();
    shell.terminal = &leaf;

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Terminal", .width = 760, .height = 480, .min_width = 320, .min_height = 200 });
    shell.window = window;
    try host.attach(window);
    try host.context.prepareTextFields(allocator, .{});
    // The user's shell at the default size; the leaf resizes it to the
    // grid of the window once laid out.
    const session = try term.Session.spawn(allocator, app, .{}, leaf.sink(), .{});
    leaf.attachSession(session);
    window.show();
    try app.run();
    leaf.detach();
    session.close();
}

test "the shell's title names the window and its exit is noticed once" {
    var shell: Shell = .{};
    Shell.notice(&shell, .{ .title = "~/src: zsh" });
    try std.testing.expectEqualStrings("~/src: zsh", shell.title[0..shell.title_len]);
    Shell.notice(&shell, .{ .exited = .{ .code = 0 } });
    try std.testing.expect(shell.exited);
}
