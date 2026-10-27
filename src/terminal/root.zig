//! A terminal: programs run on a pseudo-terminal (a Unix PTY on Linux, a
//! pseudo console on Windows) through `Session`, whose workers move bytes
//! to and from the program; `Terminal` turns the program's output into a
//! screen of cells with scrollback; `input` encodes keys, pastes, mouse
//! and focus for the program. The view leaf that shows a terminal and
//! takes keyboard, text and pointer input is `ziggurat_terminal_view`.
//!
//! ```zig
//! var term = try terminal.Terminal.init(allocator, .{});
//! defer term.deinit();
//! const session = try terminal.Session.spawn(allocator, app, .{}, sink, .{});
//! defer session.close();
//! // sink.output: term.feed(bytes), then send term.pendingReplies() back.
//! ```
const std = @import("std");

pub const parser = @import("parser.zig");
pub const screen = @import("screen.zig");
pub const width = @import("width.zig");
pub const theme = @import("theme.zig");
pub const search = @import("search.zig");
pub const keybind = @import("keybind.zig");
pub const graphics = @import("graphics.zig");
pub const mirror = @import("mirror.zig");
pub const png = @import("png.zig");
pub const input = @import("input.zig");
pub const links = @import("links.zig");
pub const selection = @import("selection.zig");
pub const pty = @import("pty.zig");
pub const session = @import("session.zig");
const terminal = @import("terminal.zig");

pub const Terminal = terminal.Terminal;
pub const Options = terminal.Options;
pub const Event = terminal.Event;
pub const Handler = terminal.Handler;
pub const ClipboardPolicy = terminal.ClipboardPolicy;
pub const default_palette = terminal.default_palette;
pub const parseColor = terminal.parseColor;

pub const Screen = screen.Screen;
pub const Cell = screen.Cell;
pub const Color = screen.Color;
pub const Style = screen.Style;
pub const Position = screen.Position;
pub const Modes = screen.Modes;
pub const Selection = selection.Selection;
pub const Theme = theme.Theme;
pub const Mirror = mirror.Mirror;
pub const snapshot = mirror.snapshot;
pub const history = mirror.history;

pub const Session = session.Session;
pub const Sink = session.Sink;
pub const SessionOptions = session.Options;
pub const Command = pty.Command;
pub const Size = pty.Size;
pub const Exit = pty.Exit;
pub const liveSessions = session.liveSessions;

test {
    std.testing.refAllDecls(@This());
    _ = terminal;
    if (@import("builtin").os.tag == .linux) _ = @import("pty_linux.zig");
}
