//! A terminal as a leaf of declarative views. The leaf paints the screen's
//! cells with the frame's rectangles and monospace labels, sizes the grid
//! to its bounds, and takes the keyboard, typed and composed text, the
//! pointer and the wheel as a text field of the UI Context, so input
//! methods compose into it like any text box. Keys go first to the app's
//! hook, then to the key bindings, then to the program as escape
//! sequences; the pointer selects text or, when the program asks, reports
//! to it; links open on Ctrl+click.
//!
//! Colors come from a theme, which follows the window's appearance unless
//! the app sets one. Searching highlights matches in the screen and the
//! scrollback.
//!
//! Resizing, registering with the Context and searching run as tasks
//! posted after paint, never inside it, and an unchanged terminal paints
//! without allocating. The window's Context needs `prepareTextFields`
//! before the leaf is shown.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const term = @import("ziggurat_terminal");
const box = @import("box.zig");

const win = struct {
    const SPI_GETWHEELSCROLLLINES: u32 = 0x0068;
    const WHEEL_PAGESCROLL: u32 = 0xffff_ffff;
    extern "user32" fn SystemParametersInfoW(action: u32, param: u32, value: ?*anyopaque, ini: u32) callconv(.winapi) c_int;
};

const Screen = term.Screen;
const Cell = term.Cell;
const Position = term.Position;
const input = term.input;
const Theme = term.Theme;
pub const Keybind = term.keybind.Keybind;
pub const Action = term.keybind.Action;
pub const SearchStatus = term.search.Status;

/// Reads and writes the clipboard for copy, paste and allowed OSC 52
/// requests.
pub const Clipboard = struct {
    context: ?*anyopaque = null,
    /// Write clipboard text into the buffer and return its length.
    read: *const fn (?*anyopaque, []u8) anyerror!usize,
    write: *const fn (?*anyopaque, []const u8) anyerror!void,
};

/// Bytes for the program, for a terminal without a `Session`.
/// What a terminal no program runs in talks to, as a stream from a server
/// whose terminal a `Mirror` frames (what is typed goes to `send`).
pub const Conn = struct {
    context: ?*anyopaque = null,
    /// Told the size the grid fits and the cell's size in pixels, for the
    /// server's terminal (`Terminal.resizePixels`).
    resize: ?*const fn (?*anyopaque, term.Size, u16, u16) anyerror!void = null,
    /// Told the theme the view takes, for the server's terminal
    /// (`Terminal.useTheme`).
    theme: ?*const fn (?*anyopaque, Theme) anyerror!void = null,
};

pub const Send = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, []const u8) anyerror!void,
};

/// What made a copy to the clipboard.
pub const CopySource = enum {
    /// The copy keys, the context menu, a secondary click that copies.
    user,
    /// `copy_on_select`.
    select,
    /// A program, with OSC 52.
    program,
};

pub const Notice = union(enum) {
    bell,
    title: []const u8,
    directory: []const u8,
    /// A desktop notification the program asks for (OSC 9, OSC 777).
    notify: struct { title: []const u8, body: []const u8 },
    /// The program ended; the screen stays until the view is released.
    exited: term.Exit,
    /// A link to open with the system: a hyperlink or an address the user
    /// Ctrl+clicked that `Hooks.open_link` left.
    open: []const u8,
    /// The terminal wrote text to the clipboard.
    copied: struct { text: []const u8, source: CopySource },
    /// How the search goes, as it changes.
    search: SearchStatus,
    /// A secondary click asks for the context menu at this window point:
    /// show `contextMenu()` there and pass the chosen item to `choose`.
    context_menu: z.Point,
};

pub const Notify = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, Notice) void,
};

/// A zoom: `steps` up (positive) or down, or back to the font's size.
pub const Zoom = struct { steps: i32 = 0, reset: bool = false };

/// Hooks that take input before the terminal does, on the main thread;
/// each reports whether it took it.
pub const Hooks = struct {
    context: ?*anyopaque = null,
    /// A key press, before the key bindings and the program. A key taken
    /// here neither reaches the program nor types its text.
    key: ?*const fn (?*anyopaque, z.KeyInput) bool = null,
    /// The wheel scrolls the scrollback by whole rows (negative up). Not
    /// asked while the program gets the wheel, as mouse reports or as
    /// arrow keys on a full-screen program's screen.
    scroll: ?*const fn (?*anyopaque, isize) bool = null,
    /// A zoom: the wheel with Control held, or a font size binding. Left,
    /// the terminal changes its font's size, a DIP a step.
    zoom: ?*const fn (?*anyopaque, Zoom) bool = null,
    /// The user's clear (`clear_screen` and the context menu's Clear),
    /// before the terminal clears; taken, nothing clears here. Not asked on
    /// a full-screen program's screen.
    clear: ?*const fn (?*anyopaque) bool = null,
    /// A link Ctrl+click opens: a hyperlink, an address, or with this hook
    /// set a file path printed as text (`/abs/path`, `~/notes.md`,
    /// `./a.go`, `src/app.go:12:3`, `main.go:250`). Hyperlinks and addresses
    /// it leaves go to `Notice.open`; paths it leaves open nothing.
    open_link: ?*const fn (?*anyopaque, []const u8, bool) bool = null,
};

pub const Font = struct {
    /// Size in DIPs.
    size: f32 = 13,
    /// From 100 to 900, of the weights the system font has. Bold text is
    /// 300 heavier, at least 700.
    weight: u16 = 400,
    /// Row height as a multiple of the font's line height; text is centered
    /// in its row.
    line_height: f32 = 1,
};

/// The room around the grid, in DIPs across and down; negative is none.
pub const Padding = struct { x: f32 = 6, y: f32 = 4 };

pub const PaddingColor = enum {
    /// The terminal's background.
    background,
    /// The backgrounds of the cells nearest to it, for rows whose every
    /// cell has a background of its own, so a full-screen program's colors
    /// reach the edges of the view.
    extend,
    /// The nearest cells' backgrounds for every row.
    extend_always,
};

/// What a secondary click does. A program that takes the mouse still gets
/// the click, unless Shift is held.
pub const RightClick = enum { context_menu, paste, copy, copy_or_paste, ignore };

pub const Options = struct {
    /// Accessible name.
    name: []const u8 = "Terminal",
    font: Font = .{},
    /// Cell size in DIPs; 0 measures the font with `measurer`.
    cell_width: f32 = 0,
    cell_height: f32 = 0,
    padding: Padding = .{},
    padding_color: PaddingColor = .background,
    /// Leave the background undrawn, so what is under the view shows
    /// through. Cells with a background color of their own still draw it.
    transparent: bool = false,
    measurer: view.Measurer = .{},
    /// Grid size preferred before the parent's flex layout applies.
    cols: u16 = 80,
    rows: u16 = 24,
    /// The colors, and with `dark_theme` those of dark windows; without a
    /// theme the terminal takes the one of the window's appearance.
    theme: ?Theme = null,
    dark_theme: ?Theme = null,
    /// The least WCAG contrast ratio text keeps with its background, from 1
    /// (none) to 21. Text with less darkens or lightens as little as
    /// reaches it; box drawing and block characters keep their colors.
    minimum_contrast: f32 = 1,
    clipboard: ?Clipboard = null,
    send: ?Send = null,
    conn: Conn = .{},
    /// Leave the screen's size to the other end of `conn`: the view only
    /// tells it the size it fits, and the screen keeps its size until the
    /// app calls `resize`, where the server's stream says it resized.
    resize_by_conn: bool = false,
    notify: ?Notify = null,
    hooks: Hooks = .{},
    /// Copy whenever a selection ends, and as Select All makes one.
    copy_on_select: bool = false,
    right_click: RightClick = .context_menu,
    /// Bindings over the platform's defaults (`term.keybind`).
    keybinds: []const Keybind = &.{},
    no_default_keybinds: bool = false,
    /// Rows a notch of a mouse wheel scrolls. By default three, and on
    /// Windows as many as its "lines to scroll" setting asks (3 unless
    /// changed).
    scroll_lines: ?u16 = null,
    /// Largest paste, in bytes.
    paste_bytes: usize = 64 * 1024,
};

/// An item of the context menu, in order, with a separator before Clear.
pub const MenuItem = enum { copy, paste, select_all, clear };
pub const MenuEntry = struct {
    item: MenuItem,
    label: []const u8,
    enabled: bool,
    /// The key bound to the item's action, for the menu to show.
    shortcut: ?Keybind,
    separator_before: bool = false,
};

/// The link Ctrl is held over, as `hoveredLink` returns it.
pub const HoveredLink = struct {
    uri: []const u8,
    /// A file path printed as text, rather than a hyperlink or an address.
    path: bool,
    /// Its cells, relative to the view.
    rect: view.Rect,
};

/// The pointer's shape over the view, for the app to set.
pub const PointerShape = union(enum) {
    /// The I-beam, over a shell, or while Shift selects over a program
    /// that takes the mouse.
    text,
    /// The arrow, while a program takes the mouse.
    arrow,
    /// The hand, over a link Ctrl is held over.
    link,
    /// The shape a program asked for with OSC 22, by its CSS name.
    named: []const u8,
};

pub const max_value = 512;
const max_preedit = 256;
const wheel_notch: f32 = 48;
const double_click_ms = 500;
/// How wide the strip at the right edge is over which the scroll bar takes
/// the pointer, in DIPs.
const scrollbar_strip: f32 = 12;
/// How long the scroll bar stays after the viewport last moved, or the
/// pointer left it, and how long it then takes to fade out, in ns.
const bar_linger: u64 = std.time.ns_per_s;
const bar_fade: u64 = 300 * std.time.ns_per_ms;
const bar_frame: u64 = 16 * std.time.ns_per_ms;

pub const TerminalView = struct {
    host: *view.Host,
    allocator: std.mem.Allocator,
    terminal: *term.Terminal,
    session: ?*term.Session = null,
    options: Options,
    bindings: term.keybind.Bindings,
    search: term.search.Search,
    id: u64 = 0,
    token: ?ui.TextFieldToken = null,
    client: ?z.TextClientToken = null,
    client_revision: u64 = 0,
    /// Bounds of the last paint, in window DIPs, and the scale.
    bounds: view.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    scale: f32 = 1,
    /// A size the grid should take, waiting for the posted task.
    wanted: ?term.Size = null,
    /// The size the grid and the program last took.
    applied: ?term.Size = null,
    queued: bool = false,
    caret: ?z.Rect = null,
    caret_sent: ?z.Rect = null,
    selection: ?term.Selection = null,
    preedit: [max_preedit]u8 = undefined,
    preedit_len: usize = 0,
    hover: ?Hover = null,
    /// Ctrl is held, as the link modifier, as last seen.
    link_held: bool = false,
    /// The pointer's last window point over the view.
    pointer: ?z.Point = null,
    /// A press opened a link: its moves and release are no one else's.
    link_press: bool = false,
    /// A key a hook or binding took types text that must not follow.
    swallow_text: bool = false,
    /// A press the program is tracking, by button.
    reported_press: ?input.MouseButton = null,
    last_click: i64 = 0,
    last_click_at: Position = .{ .row = 0, .col = 0 },
    clicks: u8 = 0,
    wheel: f32 = 0,
    zoom_wheel: f32 = 0,
    /// A touchpad gesture zooms, as it began: its momentum keeps that.
    scroll_zoom: bool = false,
    /// The primary button drags the scroll bar, held `bar_grab` DIPs below
    /// the thumb's top; `over_bar` that the pointer is over the bar's strip.
    /// `bar_lit` is whether the last paint showed it hovered or held,
    /// `bar_back` how many rows the viewport was above the bottom, and
    /// `bar_seen` when either last changed, from which the bar fades out.
    bar_held: bool = false,
    bar_grab: f32 = 0,
    over_bar: bool = false,
    bar_lit: bool = false,
    bar_back: usize = 0,
    bar_seen: ?u64 = null,
    /// The font's size after zooms; null at `options.font.size`.
    zoom_size: ?f32 = null,
    /// Whether the window's appearance is dark, and the theme in use.
    window_dark: bool = false,
    applied_theme: ?Theme = null,
    /// The search status last told.
    told_search: SearchStatus = .{},
    told_search_text: [term.search.max_text]u8 = undefined,
    exit: ?term.Exit = null,
    /// Images placements show, uploaded to the window; those let go of,
    /// until no frame draws them.
    uploads: std.ArrayList(*Upload) = .empty,
    retired: std.ArrayList(*Upload) = .empty,
    /// The last paint met a placement whose image is not uploaded.
    images_missing: bool = false,
    /// The first error from deferred work or input, for diagnostics.
    last_error: ?anyerror = null,
    value: [max_value]u8 = undefined,

    const Hover = struct { row: u64, start: u16, end: u16, path: bool = false, uri: [term.screen.Links.max_uri]u8 = undefined, len: usize = 0 };

    /// The view takes the terminal's event handler. Keep both at stable
    /// addresses while the view is shown and until `detach`; `deinit`
    /// frees the search.
    pub fn init(host: *view.Host, allocator: std.mem.Allocator, terminal: *term.Terminal, options: Options) TerminalView {
        return .{
            .host = host,
            .allocator = allocator,
            .terminal = terminal,
            .options = options,
            .bindings = .init(term.keybind.native_os, options.keybinds, options.no_default_keybinds),
            .search = .init(allocator),
        };
    }

    pub fn deinit(self: *TerminalView) void {
        self.search.deinit();
        self.releaseImages();
        for (self.retired.items) |upload| upload.destroy(self.allocator);
        self.retired.deinit(self.allocator);
        self.uploads.deinit(self.allocator);
    }

    /// Route the terminal's events here and take the theme's colors. Call
    /// once the view is at its final address.
    pub fn bind(self: *TerminalView) void {
        self.terminal.options.handler = .{ .context = self, .call = handleEvent };
        self.applyTheme();
    }

    /// Show `session`'s program; its output arrives through `sink`.
    pub fn attachSession(self: *TerminalView, session: ?*term.Session) void {
        self.session = session;
        // The new program learns the grid's size on the next placement.
        self.applied = null;
        self.invalidate();
    }

    /// The sink to start a Session with, feeding this view.
    pub fn sink(self: *TerminalView) term.Sink {
        return .{ .context = self, .output = sinkOutput, .exited = sinkExited };
    }

    /// The leaf to emit with `View.embed`. Give it a `Style.key` when
    /// siblings before it can change.
    pub fn embed(self: *TerminalView) view.Embed {
        return .{ .context = self, .measure = measure, .place = place, .paint = paint, .input = hoverInput };
    }

    /// Unregister from the Context and stop deferred work. Call before the
    /// Context detaches or the view goes away; it can be shown again.
    pub fn detach(self: *TerminalView) void {
        self.releaseImages();
        if (self.client) |client| _ = client.window.clearTextClient(client) catch {};
        self.client = null;
        if (self.token) |token| _ = token.close() catch {};
        self.token = null;
        self.wanted = null;
        self.applied = null;
        // A task still queued finds no node to serve.
        self.id = 0;
    }

    // ---- Output ------------------------------------------------------------

    /// Interpret output from the program and send any answers back.
    pub fn feed(self: *TerminalView, bytes: []const u8) void {
        self.terminal.feed(bytes);
        self.flushReplies();
        self.invalidate();
    }

    fn flushReplies(self: *TerminalView) void {
        const replies = self.terminal.pendingReplies();
        if (replies.len > 0) self.send(replies) catch |err| self.fail(err);
        self.terminal.clearReplies();
    }

    fn sinkOutput(context: *anyopaque, bytes: []const u8) void {
        const self: *TerminalView = @ptrCast(@alignCast(context));
        self.feed(bytes);
    }
    fn sinkExited(context: *anyopaque, exit: term.Exit) void {
        const self: *TerminalView = @ptrCast(@alignCast(context));
        self.exit = exit;
        self.notify(.{ .exited = exit });
        self.invalidate();
    }

    fn handleEvent(context: ?*anyopaque, event: term.Event) void {
        const self: *TerminalView = @ptrCast(@alignCast(context.?));
        switch (event) {
            .bell => self.notify(.bell),
            .title => |text| self.notify(.{ .title = text }),
            .directory => |uri| self.notify(.{ .directory = uri }),
            .notify => |n| self.notify(.{ .notify = .{ .title = n.title, .body = n.body } }),
            .clipboard_write => |text| if (self.options.clipboard) |clipboard| {
                clipboard.write(clipboard.context, text) catch |err| return self.fail(err);
                self.notify(.{ .copied = .{ .text = text, .source = .program } });
            },
            .clipboard_read => {
                const clipboard = self.options.clipboard orelse return;
                var buffer: [2048]u8 = undefined;
                const n = clipboard.read(clipboard.context, &buffer) catch |err| return self.fail(err);
                self.terminal.answerClipboard(buffer[0..@min(n, buffer.len)]);
            },
        }
    }

    fn notify(self: *TerminalView, notice: Notice) void {
        const callback = self.options.notify orelse return;
        callback.call(callback.context, notice);
    }

    fn fail(self: *TerminalView, err: anyerror) void {
        self.last_error = self.last_error orelse err;
    }

    fn invalidate(self: *TerminalView) void {
        if (self.host.context.window) |window| window.invalidate();
    }

    /// Run `run` after this paint, once.
    fn schedule(self: *TerminalView) void {
        if (self.queued) return;
        const window = self.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = run }) catch |err| return self.fail(err);
        self.queued = true;
    }

    // ---- Input to the program --------------------------------------------

    /// Send bytes to the program, as typed.
    pub fn send(self: *TerminalView, bytes: []const u8) !void {
        if (self.options.send) |callback| return callback.call(callback.context, bytes);
        const session = self.session orelse return error.NoSession;
        try session.write(bytes);
    }

    /// Send typed bytes: the view follows the cursor and the selection goes.
    fn typeBytes(self: *TerminalView, bytes: []const u8) void {
        self.send(bytes) catch |err| return self.fail(err);
        _ = self.terminal.screen.scrollViewToBottom();
        self.selection = null;
    }

    /// Paste text as the program expects it, bracketed when it asked.
    pub fn pasteText(self: *TerminalView, text: []const u8) !void {
        const out = try self.allocator.alloc(u8, input.pasteSize(text));
        defer self.allocator.free(out);
        self.typeBytes(input.paste(text, self.terminal.screen.modes.bracketed_paste, out));
    }

    /// Paste from the clipboard; false when it holds nothing.
    pub fn paste(self: *TerminalView) !bool {
        const clipboard = self.options.clipboard orelse return error.ClipboardUnavailable;
        const buffer = try self.allocator.alloc(u8, self.options.paste_bytes);
        defer self.allocator.free(buffer);
        const n = try clipboard.read(clipboard.context, buffer);
        if (n > buffer.len) return error.PasteTooLarge;
        if (n == 0) return false;
        if (!std.unicode.utf8ValidateSlice(buffer[0..n])) return error.InvalidUtf8;
        try self.pasteText(buffer[0..n]);
        return true;
    }

    /// The selected text, allocated, or null without a selection.
    pub fn selectedText(self: *TerminalView, allocator: std.mem.Allocator) !?[]u8 {
        const selection = self.selection orelse return null;
        if (selection.empty()) return null;
        return try term.selection.text(&self.terminal.screen, selection.range(&self.terminal.screen), allocator);
    }

    /// Copy the selection to the clipboard; false without one.
    pub fn copy(self: *TerminalView) !bool {
        return self.copyAs(.user);
    }

    fn copyAs(self: *TerminalView, source: CopySource) !bool {
        const clipboard = self.options.clipboard orelse return error.ClipboardUnavailable;
        const text = try self.selectedText(self.allocator) orelse return false;
        defer self.allocator.free(text);
        if (text.len == 0) return false;
        try clipboard.write(clipboard.context, text);
        self.notify(.{ .copied = .{ .text = text, .source = source } });
        return true;
    }

    /// Select everything in the scrollback and on screen.
    pub fn selectAll(self: *TerminalView) void {
        const s = &self.terminal.screen;
        self.selection = .{ .anchor = .{ .row = s.firstRow(), .col = 0 }, .head = .{ .row = s.screenRow(s.rows - 1), .col = s.cols - 1 }, .dragging = false };
        if (self.options.copy_on_select) _ = self.copyAs(.select) catch |err| self.fail(err);
        self.invalidate();
    }

    pub fn clearSelection(self: *TerminalView) void {
        self.selection = null;
        self.invalidate();
    }

    /// Clear the scrollback and the screen above the cursor's line, which
    /// moves to the top, as the user's clear does, unless `Hooks.clear`
    /// takes it; false on a full-screen program's screen.
    pub fn clearScreen(self: *TerminalView) bool {
        const s = &self.terminal.screen;
        if (s.onAlternate()) return false;
        self.selection = null;
        _ = s.scrollViewToBottom();
        defer self.invalidate();
        if (self.options.hooks.clear) |hook| if (hook(self.options.hooks.context)) return true;
        return s.clearToCursor();
    }

    /// Clear the scrollback alone.
    pub fn clearScrollback(self: *TerminalView) void {
        self.terminal.screen.clearScrollback();
        self.selection = null;
        self.invalidate();
    }

    // ---- Theme, font and search -------------------------------------------

    /// The theme the terminal takes now: the dark theme in a dark window
    /// when there is one, else the theme, else the window's appearance's.
    pub fn theme(self: *const TerminalView) Theme {
        if (self.window_dark) if (self.options.dark_theme) |dark| return dark;
        return self.options.theme orelse term.theme.default(self.window_dark);
    }

    /// Change the themes; null follows the window's appearance.
    pub fn setTheme(self: *TerminalView, light: ?Theme, dark: ?Theme) void {
        self.options.theme = light;
        self.options.dark_theme = dark;
        self.applyTheme();
        self.invalidate();
    }

    fn applyTheme(self: *TerminalView) void {
        const t = self.theme();
        if (self.applied_theme) |applied| if (std.meta.eql(applied, t)) return;
        self.applied_theme = t;
        self.terminal.useTheme(t);
        if (self.options.conn.theme) |tell| tell(self.options.conn.context, t) catch |err| self.fail(err);
    }

    /// Set the screen's size, as a server's stream says it resized, with
    /// `resize_by_conn`.
    pub fn resize(self: *TerminalView, cols: u16, rows: u16) !void {
        const s = &self.terminal.screen;
        if (cols == s.cols and rows == s.rows) return;
        try self.resizeScreen(cols, rows);
        self.invalidate();
    }

    /// Resize the screen; on the primary screen, which rewraps, the
    /// selection moves with its text.
    fn resizeScreen(self: *TerminalView, cols: u16, rows: u16) !void {
        if (self.selection) |*selection| if (!self.terminal.screen.onAlternate()) {
            var ends = [2]Position{ selection.anchor, selection.head };
            try self.terminal.resize(cols, rows, &ends);
            selection.anchor = ends[0];
            selection.head = ends[1];
            return;
        };
        self.selection = null;
        try self.terminal.resize(cols, rows, &.{});
    }

    /// Change the font; the grid takes the new size of its cells, and a
    /// zoom resets to it.
    pub fn setFont(self: *TerminalView, value: Font) void {
        self.options.font = value;
        self.zoom_size = null;
        self.invalidate();
    }

    /// The font's size now, after zooms.
    pub fn fontSize(self: *const TerminalView) f32 {
        return self.zoom_size orelse self.options.font.size;
    }

    /// Zoom as `Hooks.zoom` takes it, or change the font's size a DIP a
    /// step, down to 1, and back to `Font.size` on a reset.
    pub fn zoom(self: *TerminalView, value: Zoom) void {
        if (self.options.hooks.zoom) |hook| if (hook(self.options.hooks.context, value)) return;
        if (value.reset) {
            self.zoom_size = null;
        } else {
            self.zoom_size = @max(1, self.fontSize() + @as(f32, @floatFromInt(value.steps)));
        }
        self.invalidate();
    }

    /// Change the least contrast of text with its background.
    pub fn setMinimumContrast(self: *TerminalView, ratio: f32) void {
        self.options.minimum_contrast = ratio;
        self.invalidate();
    }

    /// Search the screen and the scrollback for text, highlighting the
    /// matches as they are found and following the output that comes; the
    /// newest is selected and shown. Matching is exact but for the case of
    /// ASCII letters. The same text keeps the selected match; empty ends
    /// the search. `Notice.search` tells how it goes.
    pub fn startSearch(self: *TerminalView, text: []const u8) !void {
        try self.search.start(text);
        self.refreshSearch();
    }
    /// Select the next match toward older output, wrapping around, and
    /// scroll it to the middle of the view unless it shows.
    pub fn searchNext(self: *TerminalView) void {
        self.search.next(&self.terminal.screen);
        self.tellSearch();
        self.invalidate();
    }
    /// Select the next match toward newer output.
    pub fn searchPrevious(self: *TerminalView) void {
        self.search.previous(&self.terminal.screen);
        self.tellSearch();
        self.invalidate();
    }
    pub fn endSearch(self: *TerminalView) void {
        self.search.end();
        self.tellSearch();
        self.invalidate();
    }
    pub fn searchStatus(self: *const TerminalView) SearchStatus {
        return self.search.status();
    }

    fn refreshSearch(self: *TerminalView) void {
        _ = self.search.update(&self.terminal.screen) catch |err| self.fail(err);
        self.tellSearch();
        self.invalidate();
    }

    fn tellSearch(self: *TerminalView) void {
        const status = self.search.status();
        const told = self.told_search;
        if (status.total == told.total and status.selected == told.selected and std.mem.eql(u8, status.text, told.text)) return;
        @memcpy(self.told_search_text[0..status.text.len], status.text);
        self.told_search = .{ .text = self.told_search_text[0..status.text.len], .total = status.total, .selected = status.selected };
        self.notify(.{ .search = status });
    }

    // ---- Context menu, links and the pointer --------------------------------

    /// The context menu: Copy, Paste, Select All, then Clear, each with the
    /// key bound to its action.
    pub fn contextMenu(self: *const TerminalView) [4]MenuEntry {
        const selected = if (self.selection) |s| !s.empty() else false;
        return .{
            .{ .item = .copy, .label = "Copy", .enabled = selected, .shortcut = self.bindings.shortcut(.copy) },
            .{ .item = .paste, .label = "Paste", .enabled = true, .shortcut = self.bindings.shortcut(.paste) },
            .{ .item = .select_all, .label = "Select All", .enabled = true, .shortcut = self.bindings.shortcut(.select_all) },
            // Clear clears as the clear key does: clearing the scrollback
            // alone would change nothing on the screen.
            .{ .item = .clear, .label = "Clear", .enabled = !self.terminal.screen.onAlternate(), .shortcut = self.bindings.shortcut(.clear_screen), .separator_before = true },
        };
    }

    /// Do what a context menu item does.
    pub fn choose(self: *TerminalView, item: MenuItem) void {
        switch (item) {
            .copy => _ = self.copy() catch |err| self.fail(err),
            .paste => _ = self.paste() catch |err| self.fail(err),
            .select_all => self.selectAll(),
            .clear => _ = self.clearScreen(),
        }
        self.invalidate();
    }

    /// The link Ctrl is held over, which a click opens and which shows
    /// underlined, relative to the view; null over none. Read it after a
    /// frame to show a preview of the link over the view.
    pub fn hoveredLink(self: *const TerminalView) ?HoveredLink {
        const hover = &(self.hover orelse return null);
        const s = &self.terminal.screen;
        const top = s.viewRow(0);
        if (hover.row < top or hover.row >= top + s.rows) return null;
        const cell = self.cellSize();
        const pad = self.padding();
        return .{ .uri = hover.uri[0..hover.len], .path = hover.path, .rect = .{
            .x = pad.x + @as(f32, @floatFromInt(hover.start)) * cell.width,
            .y = pad.y + @as(f32, @floatFromInt(hover.row - top)) * cell.height,
            .width = @as(f32, @floatFromInt(hover.end - hover.start)) * cell.width,
            .height = cell.height,
        } };
    }

    /// The pointer's shape over the grid: the hand over a link Ctrl is
    /// held over; the shape a program asked for (OSC 22); the arrow while a
    /// program takes the mouse, unless Shift is held to select; else the
    /// I-beam.
    pub fn pointerShape(self: *const TerminalView, shift: bool) PointerShape {
        // The scroll bar's, not the text's.
        if (self.bar_held or self.over_bar) return .arrow;
        if (self.hover != null) return .link;
        const takes_mouse = self.terminal.screen.modes.mouse != .none;
        if (takes_mouse and shift) return .text;
        const asked = self.terminal.pointerShape();
        if (asked.len > 0) return .{ .named = asked };
        return if (takes_mouse) .arrow else .text;
    }

    // ---- Geometry --------------------------------------------------------

    fn padding(self: *const TerminalView) struct { x: f32, y: f32 } {
        return .{ .x = @max(self.options.padding.x, 0), .y = @max(self.options.padding.y, 0) };
    }

    fn font(self: *const TerminalView) ui.Font {
        return .{ .size = self.fontSize(), .weight = weightOf(self.options.font.weight), .monospace = true };
    }
    pub fn cellSize(self: *const TerminalView) struct { width: f32, height: f32 } {
        const sample = "0123456789";
        const size = self.fontSize();
        const zoomed = size / self.options.font.size;
        const line_height = if (self.options.font.line_height > 0) self.options.font.line_height else 1;
        const w = if (self.options.cell_width > 0) self.options.cell_width * zoomed else self.options.measurer.textSize(sample, self.font()).width / sample.len;
        const h = if (self.options.cell_height > 0) self.options.cell_height * zoomed else @ceil(size * 1.3 * line_height);
        return .{ .width = @max(w, 1), .height = @max(h, 1) };
    }

    /// The grid that fits `bounds`.
    pub fn gridFor(self: *const TerminalView, bounds: view.Rect) term.Size {
        const cell = self.cellSize();
        const pad = self.padding();
        const cols: u16 = @intFromFloat(std.math.clamp(@floor((bounds.width - 2 * pad.x) / cell.width), 2, 1000));
        const rows: u16 = @intFromFloat(std.math.clamp(@floor((bounds.height - 2 * pad.y) / cell.height), 1, 1000));
        return .{ .cols = cols, .rows = rows, .width = @intFromFloat(@round(@as(f32, @floatFromInt(cols)) * cell.width * self.scale)), .height = @intFromFloat(@round(@as(f32, @floatFromInt(rows)) * cell.height * self.scale)) };
    }

    /// The view row and column under a window point, clamped to the grid.
    fn cellAt(self: *const TerminalView, point: z.Point) struct { col: u16, row: u16, inside: bool } {
        const cell = self.cellSize();
        const s = &self.terminal.screen;
        const pad = self.padding();
        const x = (point.x - self.bounds.x - pad.x) / cell.width;
        const y = (point.y - self.bounds.y - pad.y) / cell.height;
        const inside = x >= 0 and y >= 0 and x < @as(f32, @floatFromInt(s.cols)) and y < @as(f32, @floatFromInt(s.rows));
        return .{
            .col = @intFromFloat(std.math.clamp(@floor(x), 0, @as(f32, @floatFromInt(s.cols - 1)))),
            .row = @intFromFloat(std.math.clamp(@floor(y), 0, @as(f32, @floatFromInt(s.rows - 1)))),
            .inside = inside,
        };
    }

    fn measure(ptr: *anyopaque, ui_theme: ui.Theme) view.layout.Measurement {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        // The window's appearance, for a terminal that follows it.
        self.window_dark = darkColor(@truncate(ui_theme.palette.background));
        self.applyTheme();
        const cell = self.cellSize();
        const pad = self.padding();
        return .{
            .minimum = .{ .width = 4 * cell.width + 2 * pad.x, .height = cell.height + 2 * pad.y },
            .preferred = .{ .width = @as(f32, @floatFromInt(self.options.cols)) * cell.width + 2 * pad.x, .height = @as(f32, @floatFromInt(self.options.rows)) * cell.height + 2 * pad.y },
        };
    }

    fn place(ptr: *anyopaque, id: u64, bounds: view.Rect) void {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        if (self.token != null and self.id != id) {
            // A new node needs a new registration.
            self.detach();
        }
        self.id = id;
        self.bounds = bounds;
        const grid = self.gridFor(bounds);
        const sized = if (self.applied) |applied| !std.meta.eql(applied, grid) else true;
        if (sized) self.wanted = grid;
        const caret_moved = self.client != null and !std.meta.eql(self.caret, self.caret_sent);
        if (!sized and self.token != null and !caret_moved) return;
        self.schedule();
    }

    /// Posted after paint: resize, register for input, place the input
    /// method's caret, search what changed.
    fn run(ptr: *anyopaque) void {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        self.queued = false;
        if (self.id == 0) return;
        const window = self.host.context.window orelse return;
        if (self.wanted) |grid| {
            self.wanted = null;
            const cell = self.cellSize();
            self.terminal.cell_width = @intFromFloat(@round(cell.width * self.scale));
            self.terminal.cell_height = @intFromFloat(@round(cell.height * self.scale));
            const s = &self.terminal.screen;
            if (!self.options.resize_by_conn and (grid.cols != s.cols or grid.rows != s.rows)) {
                self.resizeScreen(grid.cols, grid.rows) catch |err| self.fail(err);
            }
            if (self.session) |session| session.resize(grid);
            if (self.options.conn.resize) |resize_conn| resize_conn(self.options.conn.context, grid, self.terminal.cell_width, self.terminal.cell_height) catch |err| self.fail(err);
            self.applied = grid;
            window.invalidate();
        }
        if (self.token == null) {
            if (self.host.context.registerTextField(self.id, .{ .context = self, .focus = focusCallback, .blur = blurCallback, .input = inputCallback, .action = actionCallback })) |token| {
                self.token = token;
                window.invalidate();
            } else |err| self.fail(err);
        }
        if (self.client != null and !std.meta.eql(self.caret_sent, self.caret)) {
            if (self.caret) |rect| window.setTextCaret(rect) catch |err| self.fail(err);
            self.caret_sent = self.caret;
        }
        if (self.searchStale()) self.refreshSearch();
        self.syncImages();
    }

    fn searchStale(self: *const TerminalView) bool {
        const s = &self.terminal.screen;
        return self.search.active() and (self.search.revision != s.content or self.search.alternate != s.onAlternate() or self.search.pushed != s.pushed);
    }

    // ---- Images ----------------------------------------------------------

    /// An image uploaded to the window: its pixels premultiplied BGRA, at
    /// most as many as the window takes, sampled down from bigger ones.
    const Upload = struct {
        alternate: bool,
        id: u32,
        generation: u64,
        /// 0 when it could not be uploaded, which is not tried again.
        identity: u64 = 0,
        lease: ui.drawing.Lease,
        pixels: []u8 = &.{},
        level: [1]ui.drawing.ImageLevel = undefined,
        /// A paint drew it.
        seen: bool = true,

        fn imageView(self: *Upload) ui.drawing.ImageView {
            return .{ .lease = &self.lease, .identity = self.identity, .levels = &self.level };
        }

        fn destroy(self: *Upload, allocator: std.mem.Allocator) void {
            allocator.free(self.pixels);
            allocator.destroy(self);
        }
    };

    /// Images in layers by their z, as Ghostty draws them.
    const ImageLayer = enum { below_background, below_text, above_text };

    fn layerOf(z_index: i32) ImageLayer {
        if (z_index < -(1 << 30)) return .below_background;
        if (z_index < 0) return .below_text;
        return .above_text;
    }

    fn uploadOf(self: *const TerminalView, alternate: bool, image: *const term.graphics.Image) ?*Upload {
        for (self.uploads.items) |upload| {
            if (upload.alternate == alternate and upload.id == image.id and upload.generation == image.generation) return upload;
        }
        return null;
    }

    /// Whether a placement shows some of itself in the view.
    fn placementShows(self: *const TerminalView, p: term.graphics.Placement, size: term.graphics.Layout) bool {
        if (p.virtual or size.width == 0 or size.height == 0 or size.src_w == 0 or size.src_h == 0) return false;
        const t = self.terminal;
        const top = t.imagesTop();
        return p.row + size.rows > top and p.row < top + t.screen.rows;
    }

    fn imagesStale(self: *const TerminalView) bool {
        if (self.images_missing or self.retired.items.len > 0) return true;
        for (self.uploads.items) |upload| if (!upload.seen) return true;
        return false;
    }

    /// Draw the placements of a layer, within the grid.
    fn paintImages(self: *TerminalView, frame: *ui.Frame, layer: ImageLayer, ox: f32, oy: f32, cw: f32, ch: f32) !void {
        const t = self.terminal;
        if (t.cell_width == 0 or t.cell_height == 0) return;
        const storage = t.activeImages();
        const alternate = t.screen.onAlternate();
        const top: i64 = @intCast(t.imagesTop());
        const scale = self.scale;
        const grid: view.Rect = .{ .x = ox, .y = oy, .width = @as(f32, @floatFromInt(t.screen.cols)) * cw, .height = @as(f32, @floatFromInt(t.screen.rows)) * ch };
        for (storage.placements.items) |p| {
            if (layerOf(p.z) != layer) continue;
            const image = storage.image(p.image_id) orelse continue;
            const size = term.graphics.layout(p, image.*, t.cell_width, t.cell_height);
            if (!self.placementShows(p, size)) continue;
            const upload = self.uploadOf(alternate, image) orelse {
                self.images_missing = true;
                continue;
            };
            upload.seen = true;
            if (upload.identity == 0) continue;
            const rects = imageRects(p, size, image.*, .{ .x = ox + @as(f32, @floatFromInt(p.col)) * cw, .y = oy + @as(f32, @floatFromInt(@as(i64, @intCast(p.row)) - top)) * ch }, scale, grid) orelse continue;
            const whole = rects.whole;
            const clip = rects.clip;
            try frame.pushClip(clip);
            frame.image(whole, upload.imageView(), .{}) catch |err| self.fail(err);
            try frame.popClip();
        }
    }

    /// Upload the images placements show, and let go of the rest. Runs
    /// outside paint.
    fn syncImages(self: *TerminalView) void {
        const t = self.terminal;
        const storage = t.activeImages();
        const alternate = t.screen.onAlternate();
        var changed = false;
        var i: usize = 0;
        while (i < self.uploads.items.len) {
            const upload = self.uploads.items[i];
            const image = if (upload.alternate == alternate) storage.image(upload.id) else null;
            const keep = if (image) |img| img.generation == upload.generation and self.imageShows(img.id) else false;
            if (keep) {
                i += 1;
                continue;
            }
            _ = self.uploads.swapRemove(i);
            self.retire(upload);
            changed = true;
        }
        for (storage.placements.items) |p| {
            const image = storage.image(p.image_id) orelse continue;
            if (self.uploadOf(alternate, image) != null) continue;
            if (!self.placementShows(p, term.graphics.layout(p, image.*, t.cell_width, t.cell_height))) continue;
            self.uploadImage(alternate, image) catch |err| {
                self.fail(err);
                continue;
            };
            changed = true;
        }
        self.freeRetired();
        if (changed) self.invalidate();
    }

    fn imageShows(self: *const TerminalView, id: u32) bool {
        const t = self.terminal;
        const storage = t.activeImages();
        const image = storage.image(id) orelse return false;
        for (storage.placements.items) |p| {
            if (p.image_id == id and self.placementShows(p, term.graphics.layout(p, image.*, t.cell_width, t.cell_height))) return true;
        }
        return false;
    }

    fn uploadImage(self: *TerminalView, alternate: bool, image: *const term.graphics.Image) !void {
        try self.uploads.ensureUnusedCapacity(self.allocator, 1);
        const kept = try self.allocator.create(Upload);
        kept.* = .{ .alternate = alternate, .id = image.id, .generation = image.generation, .lease = .init(std.Thread.getCurrentId()) };
        errdefer kept.destroy(self.allocator);
        // Halve what the window cannot take.
        var width = image.width;
        var height = image.height;
        while (width > 16384 or height > 16384 or @as(u64, width) * height > 16 * 1024 * 1024) {
            width = (width + 1) / 2;
            height = (height + 1) / 2;
        }
        kept.pixels = try self.allocator.alloc(u8, @as(usize, width) * height * 4);
        convertImage(image.*, width, height, kept.pixels);
        kept.level = .{.{ .pixels = kept.pixels.ptr, .byte_len = kept.pixels.len, .width = width, .height = height, .stride = width * 4 }};
        kept.identity = try ui.drawing.reserveRasterIdentity();
        self.host.context.uploadImage(kept.imageView()) catch |err| {
            // Kept, so as not to try again.
            kept.identity = 0;
            self.fail(err);
        };
        self.uploads.appendAssumeCapacity(kept);
    }

    fn retire(self: *TerminalView, kept: *Upload) void {
        if (kept.identity != 0 and self.host.context.window != null) _ = self.host.context.releaseImage(kept.identity) catch |err| self.fail(err);
        self.retired.append(self.allocator, kept) catch {
            // With nowhere to wait, it goes now; frames end before the
            // window lets go of the image.
            kept.destroy(self.allocator);
        };
    }

    /// Free the pixels of images no frame draws any longer.
    fn freeRetired(self: *TerminalView) void {
        var i: usize = 0;
        while (i < self.retired.items.len) {
            const kept = self.retired.items[i];
            kept.lease.ensureUnused() catch {
                i += 1;
                continue;
            };
            _ = self.retired.swapRemove(i);
            kept.destroy(self.allocator);
        }
    }

    fn releaseImages(self: *TerminalView) void {
        for (self.uploads.items) |kept| self.retire(kept);
        self.uploads.clearRetainingCapacity();
        self.freeRetired();
    }

    // ---- Paint -----------------------------------------------------------

    const Colors = struct { fg: u24, bg: u24 };
    const Found = enum { none, match, selected };

    /// The cell's colors: its own, the selection's, or a search match's.
    fn colorsOf(self: *const TerminalView, cell: Cell, selected: bool, found: Found) Colors {
        const t = self.terminal;
        const th = self.applied_theme orelse self.theme();
        const style = cell.style;
        var fg = t.rgb(style.fg, true);
        var bg = t.rgb(style.bg, false);
        if (style.attrs.inverse) std.mem.swap(u24, &fg, &bg);
        if (t.screen.modes.reverse_video) std.mem.swap(u24, &fg, &bg);
        if (self.options.minimum_contrast > 1 and !keepsColor(cell.cp)) fg = contrasted(fg, bg, self.options.minimum_contrast);
        if (style.attrs.dim) fg = blend(fg, bg);
        switch (found) {
            .none => if (selected) {
                bg = th.selectionColor();
                if (th.selection_text) |text| fg = text;
            },
            .match, .selected => {
                const sc = th.searchColors();
                bg = if (found == .selected) sc.selected else sc.match;
                fg = if (found == .selected) sc.selected_text else sc.text;
            },
        }
        if (style.attrs.hidden) fg = bg;
        return .{ .fg = fg, .bg = bg };
    }

    /// Whether the cell has a background of its own, rather than the
    /// terminal's.
    fn ownBackground(self: *const TerminalView, cell: Cell) bool {
        return cell.style.bg.kind != .default or cell.style.attrs.inverse != self.terminal.screen.modes.reverse_video;
    }

    fn foundAt(self: *const TerminalView, row: u64, col: usize) Found {
        if (!self.search.active()) return .none;
        return switch (self.search.at(.{ .row = row, .col = @intCast(@min(col, std.math.maxInt(u16))) })) {
            .none => .none,
            .match => .match,
            .selected => .selected,
        };
    }

    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: view.Rect) anyerror!void {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        self.bounds = bounds;
        self.scale = frame.size.scale;
        const t = self.terminal;
        const s = &t.screen;
        const cell = self.cellSize();
        const pad = self.padding();
        const ox = bounds.x + pad.x;
        const oy = bounds.y + pad.y;
        const background = if (s.modes.reverse_video) t.foreground else t.background;
        if (!self.options.transparent) frame.rect(bounds, background);
        try frame.pushClip(bounds);
        if (self.options.padding_color != .background) self.extendPadding(frame, bounds, ox, oy, cell.width, cell.height);
        const range = if (self.selection) |selection| (if (selection.empty()) null else selection.range(s)) else null;
        const offset = s.viewportOffset();
        for (self.uploads.items) |upload| upload.seen = false;
        self.images_missing = false;
        try self.paintImages(frame, .below_background, ox, oy, cell.width, cell.height);
        for (0..s.rows) |y| {
            const abs = s.viewRow(y);
            const line = s.rowAt(abs) orelse continue;
            const top = oy + @as(f32, @floatFromInt(y)) * cell.height;
            // Backgrounds, merged across cells of one color.
            var x: usize = 0;
            while (x < line.cells.len) {
                const first = line.cells[x];
                const bg = self.colorsOf(first, selectedAt(range, abs, x), self.foundAt(abs, x)).bg;
                const shows = bg != background or (self.options.transparent and self.ownBackground(first));
                var end = x + 1;
                while (end < line.cells.len and self.colorsOf(line.cells[end], selectedAt(range, abs, end), self.foundAt(abs, end)).bg == bg) end += 1;
                if (shows or selectedAt(range, abs, x) or self.foundAt(abs, x) != .none) frame.rect(.{ .x = ox + @as(f32, @floatFromInt(x)) * cell.width, .y = top, .width = @as(f32, @floatFromInt(end - x)) * cell.width, .height = cell.height }, bg);
                x = end;
            }
            // Selection past the end of a short scrollback line.
            if (range) |r| if (line.cells.len < s.cols and selectedAt(r, abs, line.cells.len)) {
                frame.rect(.{ .x = ox + @as(f32, @floatFromInt(line.cells.len)) * cell.width, .y = top, .width = @as(f32, @floatFromInt(s.cols - line.cells.len)) * cell.width, .height = cell.height }, self.theme().selectionColor());
            };
        }
        try self.paintImages(frame, .below_text, ox, oy, cell.width, cell.height);
        var boxes: BoxPainter = .{ .frame = frame };
        for (0..s.rows) |y| {
            const abs = s.viewRow(y);
            const line = s.rowAt(abs) orelse continue;
            self.paintText(frame, &boxes, line.cells, abs, range, ox, oy + @as(f32, @floatFromInt(y)) * cell.height, cell.width, cell.height);
        }
        boxes.flush();
        try self.paintImages(frame, .above_text, ox, oy, cell.width, cell.height);
        if (self.hover) |hover| if (hover.row >= s.viewRow(0) and hover.row < s.viewRow(s.rows)) {
            if (s.rowAt(hover.row)) |line| if (hover.start < line.cells.len) {
                const top = oy + @as(f32, @floatFromInt(hover.row - s.viewRow(0))) * cell.height;
                const fg = self.colorsOf(line.cells[hover.start], false, .none).fg;
                frame.rect(.{ .x = ox + @as(f32, @floatFromInt(hover.start)) * cell.width, .y = top + cell.height - 1, .width = @as(f32, @floatFromInt(hover.end - hover.start)) * cell.width, .height = 1 }, fg);
            };
        };
        const focused = self.token != null and frame.context.input_state.focused == self.id;
        self.caret = null;
        // The cursor, when its row is in view.
        const cursor_row = @as(usize, s.cursor.y) + offset;
        if (s.modes.cursor_visible and cursor_row < s.rows and self.exit == null) {
            const line = s.row(s.cursor.y);
            const under = line[s.cursor.x];
            const span: f32 = if (under.wide == .wide) 2 else 1;
            const rect: view.Rect = .{ .x = ox + @as(f32, @floatFromInt(s.cursor.x)) * cell.width, .y = oy + @as(f32, @floatFromInt(cursor_row)) * cell.height, .width = span * cell.width, .height = cell.height };
            self.caret = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
            const color = ui.Color.rgb(t.cursor_color);
            if (self.preedit_len > 0 and focused) {
                self.paintPreedit(frame, rect, cell.width);
            } else if (!focused) {
                frame.strokeRect(rect, 0, 1, color);
            } else switch (s.modes.cursor_shape) {
                .block => {
                    frame.rect(rect, t.cursor_color);
                    if (under.cp != 0 and under.wide != .spacer) {
                        const text_color = (self.applied_theme orelse self.theme()).cursor_text orelse self.colorsOf(under, false, .none).bg;
                        if (box.drawn(under.cp)) {
                            var cursor_box: BoxPainter = .{ .frame = frame };
                            cursor_box.cell(under.cp, rect, text_color);
                            cursor_box.flush();
                        } else {
                            var bytes: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(under.cp, &bytes) catch 0;
                            frame.labelFont(.{ .x = rect.x, .y = rect.y, .width = rect.width + cell.width, .height = rect.height }, bytes[0..n], text_color, self.fontFor(under));
                        }
                    }
                },
                .underline => frame.rect(.{ .x = rect.x, .y = rect.y + rect.height - 2, .width = rect.width, .height = 2 }, t.cursor_color),
                .bar => frame.rect(.{ .x = rect.x, .y = rect.y, .width = 2, .height = rect.height }, t.cursor_color),
            }
        }
        self.paintScrollbar(frame, bounds, offset);
        try frame.popClip();
        // Output moved the cursor, changed what a search finds or which
        // images show: the posted task follows.
        if ((self.client != null and !std.meta.eql(self.caret, self.caret_sent)) or self.searchStale() or self.imagesStale()) self.schedule();
        if (self.token) |token| try frame.textField(token, bounds, true);
        // Until the leaf is a registered text field nothing can take input
        // for it, so the box reads as read-only.
        try frame.semantic(.{ .id = id, .role = .text_box, .name = self.options.name, .value = self.cursorLine(), .bounds = bounds, .focused = focused, .read_only = self.token == null });
    }

    /// Where the viewport is in the scrollback, as overlay scroll bars show
    /// it: as the viewport moves, and while the pointer is over the bar's
    /// strip or drags it, when it widens; a while after, it fades out.
    fn paintScrollbar(self: *TerminalView, frame: *ui.Frame, bounds: view.Rect, offset: usize) void {
        const v = &self.host.view;
        const shown = self.scrollbarShown(v.time(), offset);
        if (shown.wake) |deadline| v.wakeAt(deadline);
        const alpha = shown.alpha orelse return;
        const thumb = self.thumbOf(bounds.height);
        var width: f32 = 4;
        var inset: f32 = 3;
        var color = ui.Color.rgb(self.terminal.foreground).withAlpha(0.35 * alpha);
        if (self.bar_lit) {
            width = 8;
            inset = 2;
            if (self.bar_held) color = ui.Color.rgb(self.terminal.foreground).withAlpha(0.5);
        }
        frame.roundedRect(.{ .x = bounds.x + bounds.width - inset - width, .y = bounds.y + thumb.y + 2, .width = width, .height = thumb.height - 4 }, width / 2, color);
    }

    /// How the scroll bar shows at `now`, with the viewport `offset` rows
    /// above the bottom: its opacity, null when hidden, and when the next
    /// paint should come as it fades.
    fn scrollbarShown(self: *TerminalView, now: u64, offset: usize) struct { alpha: ?f32, wake: ?u64 = null } {
        if (offset != self.bar_back) {
            self.bar_back = offset;
            self.bar_seen = now;
        }
        const lit = self.bar_held or self.over_bar;
        if (self.bar_lit and !lit) self.bar_seen = now;
        self.bar_lit = lit;
        if (self.terminal.screen.historyCount() == 0) return .{ .alpha = null };
        if (lit) return .{ .alpha = 1 };
        const seen = self.bar_seen orelse return .{ .alpha = null };
        const since = now -| seen;
        if (since < bar_linger) return .{ .alpha = 1, .wake = seen + bar_linger };
        if (since < bar_linger + bar_fade) return .{ .alpha = 1 - @as(f32, @floatFromInt(since - bar_linger)) / @as(f32, @floatFromInt(bar_fade)), .wake = now + bar_frame };
        return .{ .alpha = null };
    }

    /// The scroll bar's thumb in a track `track` DIPs high: its top and
    /// height. The scrollback is not empty.
    fn thumbOf(self: *const TerminalView, track: f32) struct { y: f32, height: f32 } {
        const s = &self.terminal.screen;
        const history: f32 = @floatFromInt(s.historyCount());
        const rows: f32 = @floatFromInt(s.rows);
        const height = @max(track * rows / (history + rows), 24);
        const from_top = history - @as(f32, @floatFromInt(s.viewportOffset()));
        return .{ .y = (track - height) * from_top / @max(history, 1), .height = height };
    }

    /// Whether the scroll bar takes the pointer at a window point: over its
    /// strip while there is a scrollback, which shows the bar, or while it
    /// is dragged.
    fn overScrollbar(self: *const TerminalView, point: z.Point) bool {
        if (self.bar_held) return true;
        const b = self.bounds;
        if (point.x < b.x + b.width - scrollbar_strip or point.x >= b.x + b.width or point.y < b.y or point.y >= b.y + b.height) return false;
        return self.terminal.screen.historyCount() > 0;
    }

    /// The pointer moved to `point`, or left: whether it is over the bar
    /// changed, which the bar and the pointer's shape show.
    fn trackScrollbar(self: *TerminalView, point: ?z.Point) bool {
        const over = if (point) |p| self.overScrollbar(p) else self.bar_held;
        if (over == self.over_bar) return false;
        self.over_bar = over;
        self.invalidate();
        return true;
    }

    /// Scroll the scrollback so that the thumb's top is `bar_grab` above
    /// `y`, a window coordinate.
    fn dragScrollbar(self: *TerminalView, y: f32) void {
        const s = &self.terminal.screen;
        const history = s.historyCount();
        if (history == 0) return;
        const height = self.thumbOf(self.bounds.height).height;
        const travel = self.bounds.height - height;
        if (travel <= 0) return;
        const f = std.math.clamp((y - self.bounds.y - self.bar_grab) / travel, 0, 1);
        const to: usize = @intFromFloat(@round(f * @as(f32, @floatFromInt(history))));
        const delta = @as(isize, @intCast(history - to)) - @as(isize, @intCast(s.viewportOffset()));
        if (delta != 0 and s.scrollView(delta)) self.invalidate();
    }

    /// Paint the padding with the backgrounds of the cells nearest to it:
    /// a row's beside it, the top and bottom rows' above and below the
    /// grid. A lone character in inverse video, as a program draws its own
    /// cursor, keeps its background in its cell.
    fn extendPadding(self: *const TerminalView, frame: *ui.Frame, bounds: view.Rect, ox: f32, oy: f32, cw: f32, ch: f32) void {
        const s = &self.terminal.screen;
        const always = self.options.padding_color == .extend_always;
        const right = bounds.x + bounds.width;
        const grid_right = ox + @as(f32, @floatFromInt(s.cols)) * cw;
        for (0..s.rows) |y| {
            const line = (s.rowAt(s.viewRow(y)) orelse continue).cells;
            if (line.len < s.cols or !(always or self.filled(line))) continue;
            const top = oy + @as(f32, @floatFromInt(y)) * ch;
            const bottom = top + ch;
            const first = line[0];
            const last = line[line.len - 1];
            const y0 = if (y == 0) bounds.y else top;
            const y1 = if (y + 1 == s.rows) bounds.y + bounds.height else bottom;
            if (!loneInverse(line, 0)) frame.rect(.{ .x = bounds.x, .y = y0, .width = ox - bounds.x, .height = y1 - y0 }, self.colorsOf(first, false, .none).bg);
            if (!loneInverse(line, line.len - 1)) frame.rect(.{ .x = grid_right, .y = y0, .width = right - grid_right, .height = y1 - y0 }, self.colorsOf(last, false, .none).bg);
            if (y != 0 and y + 1 != s.rows) continue;
            // Above the top row and below the bottom one, cell by cell.
            const band_y = if (y == 0) bounds.y else bottom;
            const band_h = if (y == 0) top - bounds.y else bounds.y + bounds.height - bottom;
            if (band_h <= 0) continue;
            for (line, 0..) |c, x| {
                if (loneInverse(line, x)) continue;
                frame.rect(.{ .x = ox + @as(f32, @floatFromInt(x)) * cw, .y = band_y, .width = cw, .height = band_h }, self.colorsOf(c, false, .none).bg);
            }
        }
    }

    /// Whether every cell of a row has a background of its own.
    fn filled(self: *const TerminalView, line: []const Cell) bool {
        for (line) |c| if (!self.ownBackground(c)) return false;
        return true;
    }

    fn fontFor(self: *const TerminalView, cell: Cell) ui.Font {
        var value = self.font();
        if (cell.style.attrs.bold) value.weight = weightOf(@min(@max(self.options.font.weight + 300, 700), 900));
        value.italic = cell.style.attrs.italic;
        return value;
    }

    /// Text in runs of one color and font. Wide characters go one by one at
    /// their cells, so a fallback font's advance cannot shift the grid.
    fn paintText(self: *TerminalView, frame: *ui.Frame, boxes: *BoxPainter, cells: []const Cell, abs: u64, range: ?term.selection.Range, ox: f32, top: f32, cw: f32, ch: f32) void {
        var glyphs: [1024]u8 = undefined;
        var x: usize = 0;
        while (x < cells.len) {
            // Stop emitting text when the frame runs low on commands, rather
            // than fail the whole frame.
            const buffer = &frame.context.command_buffer;
            if (buffer.storage.len - buffer.len < 64) return;
            const first = cells[x];
            if (first.wide == .spacer or first.cp == 0 or first.cp == ' ') {
                if (first.style.attrs.underline != .none or first.style.attrs.strike or first.style.attrs.overline) self.decorate(frame, first, selectedAt(range, abs, x), self.foundAt(abs, x), ox + @as(f32, @floatFromInt(x)) * cw, top, cw, ch);
                x += 1;
                continue;
            }
            const colors = self.colorsOf(first, selectedAt(range, abs, x), self.foundAt(abs, x));
            if (box.drawn(first.cp)) {
                // Drawn rather than taken from the font. Curves take a
                // command per row, so they wait for room.
                const span: f32 = if (first.wide == .wide) 2 else 1;
                const left = ox + @as(f32, @floatFromInt(x)) * cw;
                if (!first.style.attrs.hidden and (!box.scanned(first.cp) or buffer.storage.len - buffer.len >= 256)) boxes.cell(first.cp, .{ .x = left, .y = top, .width = span * cw, .height = ch }, colors.fg);
                const a = first.style.attrs;
                if (a.underline != .none or a.strike or a.overline) self.decorate(frame, first, selectedAt(range, abs, x), self.foundAt(abs, x), left, top, cw, ch);
                x += if (first.wide == .wide) 2 else 1;
                continue;
            }
            const face = self.fontFor(first);
            var len: usize = 0;
            var end = x;
            while (end < cells.len) {
                const c = cells[end];
                if (c.wide == .spacer or box.drawn(c.cp)) break;
                if (end > x and (c.wide == .wide or first.wide == .wide)) break;
                if (c.cp != 0 and c.cp != ' ') {
                    const other = self.colorsOf(c, selectedAt(range, abs, end), self.foundAt(abs, end));
                    if (other.fg != colors.fg or !std.meta.eql(self.fontFor(c), face)) break;
                } else if (!std.meta.eql(self.fontFor(c), face) and c.style.attrs.underline != .none) break;
                if (len + 4 > glyphs.len) break;
                len += std.unicode.utf8Encode(if (c.cp == 0) ' ' else c.cp, glyphs[len..]) catch break;
                end += if (c.wide == .wide) 2 else 1;
                if (c.wide == .wide) break;
            }
            // Trailing blanks need no glyphs.
            var trimmed = len;
            while (trimmed > 0 and glyphs[trimmed - 1] == ' ') trimmed -= 1;
            const left = ox + @as(f32, @floatFromInt(x)) * cw;
            const cells_wide: f32 = @floatFromInt(end - x);
            if (!first.style.attrs.hidden and trimmed > 0) frame.labelFont(.{ .x = left, .y = top, .width = (cells_wide + 1) * cw, .height = ch }, glyphs[0..trimmed], colors.fg, face);
            for (x..end) |i| {
                const c = cells[i];
                if (c.style.attrs.underline != .none or c.style.attrs.strike or c.style.attrs.overline) self.decorate(frame, c, selectedAt(range, abs, i), self.foundAt(abs, i), ox + @as(f32, @floatFromInt(i)) * cw, top, cw, ch);
            }
            x = end;
        }
    }

    /// Draws the characters the terminal draws itself, merging their
    /// rectangles where they meet in one color, as runs of lines do across
    /// cells, so a screen of borders takes few commands.
    const BoxPainter = struct {
        frame: *ui.Frame,
        color: u24 = 0,
        pending: ?box.Fill = null,

        /// Draw `cp` in its cell, snapped to the frame's device pixels.
        fn cell(self: *BoxPainter, cp: u21, at: view.Rect, color: u24) void {
            if (color != self.color) {
                self.flush();
                self.color = color;
            }
            const s = self.frame.size.scale;
            box.draw(cp, @round(at.x * s), @round(at.y * s), @round((at.x + at.width) * s), @round((at.y + at.height) * s), s, self);
        }

        pub fn fill(self: *BoxPainter, f: box.Fill) void {
            if (self.pending) |*p| if (p.alpha == f.alpha) {
                if (p.y0 == f.y0 and p.y1 == f.y1 and f.x0 <= p.x1 and f.x1 >= p.x0) {
                    p.x0 = @min(p.x0, f.x0);
                    p.x1 = @max(p.x1, f.x1);
                    return;
                }
                if (p.x0 == f.x0 and p.x1 == f.x1 and f.y0 <= p.y1 and f.y1 >= p.y0) {
                    p.y0 = @min(p.y0, f.y0);
                    p.y1 = @max(p.y1, f.y1);
                    return;
                }
            };
            self.flush();
            self.pending = f;
        }

        fn flush(self: *BoxPainter) void {
            const f = self.pending orelse return;
            self.pending = null;
            const s = self.frame.size.scale;
            const rect: view.Rect = .{ .x = f.x0 / s, .y = f.y0 / s, .width = (f.x1 - f.x0) / s, .height = (f.y1 - f.y0) / s };
            if (f.alpha >= 1) self.frame.rect(rect, self.color) else self.frame.roundedRect(rect, 0, ui.Color.rgb(self.color).withAlpha(f.alpha));
        }
    };

    fn decorate(self: *const TerminalView, frame: *ui.Frame, cell: Cell, selected: bool, found: Found, left: f32, top: f32, cw: f32, ch: f32) void {
        const a = cell.style.attrs;
        const colors = self.colorsOf(cell, selected, found);
        const width = if (cell.wide == .wide) 2 * cw else cw;
        const line_color = if (cell.style.underline_color.kind == .default) colors.fg else self.terminal.rgb(cell.style.underline_color, true);
        switch (a.underline) {
            .none => {},
            .double => {
                frame.rect(.{ .x = left, .y = top + ch - 4, .width = width, .height = 1 }, line_color);
                frame.rect(.{ .x = left, .y = top + ch - 2, .width = width, .height = 1 }, line_color);
            },
            .dotted, .dashed => {
                const dash: f32 = if (a.underline == .dotted) 1 else 3;
                var at = left;
                while (at < left + width) : (at += 2 * dash) frame.rect(.{ .x = at, .y = top + ch - 2, .width = @min(dash, left + width - at), .height = 1 }, line_color);
            },
            else => frame.rect(.{ .x = left, .y = top + ch - 2, .width = width, .height = 1 }, line_color),
        }
        if (a.strike) frame.rect(.{ .x = left, .y = top + ch / 2, .width = width, .height = 1 }, colors.fg);
        if (a.overline) frame.rect(.{ .x = left, .y = top, .width = width, .height = 1 }, colors.fg);
    }

    /// Text being composed shows at the cursor, underlined.
    fn paintPreedit(self: *TerminalView, frame: *ui.Frame, at: view.Rect, cw: f32) void {
        const text = self.preedit[0..self.preedit_len];
        var cells: usize = 0;
        var iterator = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (iterator.nextCodepoint()) |cp| cells += term.width.of(cp);
        const width = @as(f32, @floatFromInt(@max(cells, 1))) * cw;
        const t = self.terminal;
        frame.rect(.{ .x = at.x, .y = at.y, .width = width, .height = at.height }, t.background);
        frame.labelFont(.{ .x = at.x, .y = at.y, .width = width + cw, .height = at.height }, text, t.foreground, self.font());
        frame.rect(.{ .x = at.x, .y = at.y + at.height - 2, .width = width, .height = 1 }, t.foreground);
    }

    /// The cursor's line, read as the text box's value.
    fn cursorLine(self: *TerminalView) []const u8 {
        const s = &self.terminal.screen;
        var len: usize = 0;
        for (s.row(s.cursor.y)) |c| {
            if (c.wide == .spacer) continue;
            if (len + 4 > self.value.len) break;
            len += std.unicode.utf8Encode(if (c.cp == 0) ' ' else c.cp, self.value[len..]) catch break;
        }
        while (len > 0 and self.value[len - 1] == ' ') len -= 1;
        return self.value[0..len];
    }

    // ---- Input -----------------------------------------------------------

    fn textClient(self: *TerminalView) z.TextClient {
        return .{ .context = self, .owner = self.host.context.window.?.app.owner, .read = clientRead, .change = clientChange, .unbound = clientUnbound };
    }

    fn clientRead(ptr: *anyopaque, _: z.Window, _: []u8) anyerror!z.text.Snapshot {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        // Nothing typed stays here; it goes to the program.
        return .{ .range = .{ .start = 0, .end = 0 }, .selection = .{ .anchor = 0, .caret = 0 }, .revision = self.client_revision, .bytes = 0 };
    }
    fn clientChange(ptr: *anyopaque, _: z.Window, change: z.text.Change) anyerror!z.text.ChangeResult {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        switch (change) {
            .select => {},
            .replace => |value| {
                self.preedit_len = 0;
                self.typeText(value.text);
                self.client_revision += 1;
            },
        }
        return .applied;
    }
    fn clientUnbound(ptr: *anyopaque, _: z.Window, _: z.text.UnbindReason) void {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        self.client = null;
        self.caret_sent = null;
        self.preedit_len = 0;
    }

    fn focusCallback(ptr: *anyopaque, scope: *ui.TextFieldScope) anyerror!z.TextClientToken {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        const window = scope.window();
        const token = try window.setTextClient(self.textClient());
        self.client = token;
        self.caret_sent = null;
        if (input.focus(true, self.terminal.screen.modes)) |bytes| self.send(bytes) catch {};
        return token;
    }
    fn blurCallback(ptr: *anyopaque, window: z.Window) anyerror!void {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        if (self.client) |client| _ = try window.clearTextClient(client);
        self.client = null;
        self.preedit_len = 0;
        self.reported_press = null;
        self.setLinkHeld(false);
        if (input.focus(false, self.terminal.screen.modes)) |bytes| self.send(bytes) catch {};
    }
    fn actionCallback(_: *anyopaque, _: *ui.TextFieldScope, _: ui.TextFieldAction) anyerror!ui.TextFieldResult {
        return .{};
    }

    fn inputCallback(ptr: *anyopaque, _: *ui.TextFieldScope, event: z.Event) anyerror!ui.TextFieldResult {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        const handled = self.handle(event);
        if (handled) self.invalidate();
        return .{ .handled = handled };
    }

    /// One input event for the focused terminal; true when it was used.
    pub fn handle(self: *TerminalView, event: z.Event) bool {
        switch (event) {
            .key_input => |k| return self.key(k),
            .edit_key => |edit| return self.key(.{ .key = switch (edit.key) {
                inline else => |k| @field(z.KeyCode, @tagName(k)),
            }, .modifiers = .{ .control = edit.control, .shift = edit.shift } }),
            .text_input => |text| {
                self.preedit_len = 0;
                self.typeText(text.text);
                return true;
            },
            .text_preedit => |preedit| {
                const n = @min(preedit.text.len, max_preedit);
                @memcpy(self.preedit[0..n], preedit.text[0..n]);
                self.preedit_len = n;
                return true;
            },
            .text_preedit_cancel => {
                self.preedit_len = 0;
                return true;
            },
            .pointer_down => |press| return self.pointerDown(press),
            .pointer_up => |press| return self.pointerUp(press),
            .pointer_move => |point| return self.pointerMove(point),
            .wheel => |wheel| return self.scrollWheel(wheel.position, wheel.delta.y, .{ .control = self.link_held }, wheel.precise, wheel.momentum),
            else => return false,
        }
    }

    fn typeText(self: *TerminalView, text: []const u8) void {
        if (self.swallow_text) {
            // The text of a key a hook or binding took.
            self.swallow_text = false;
            return;
        }
        if (input.typed(text)) self.typeBytes(text);
    }

    fn key(self: *TerminalView, k: z.KeyInput) bool {
        const m = k.modifiers;
        self.swallow_text = false;
        self.setLinkHeld(k.key == .control or (m.control and k.key != .shift and k.key != .alt and k.key != .super));
        if (self.options.hooks.key) |hook| if (hook(self.options.hooks.context, k)) {
            self.swallow_text = typesText(k);
            return true;
        };
        if (self.bindings.find(.of(m), k.key)) |binding| {
            if (self.perform(binding.action, binding.performable) or !binding.performable) {
                self.swallow_text = typesText(k);
                return true;
            }
        }
        // Super chords are the app's shortcuts.
        if (m.super) return false;
        var buffer: [input.max_key]u8 = undefined;
        const bytes = input.key(k, self.terminal.screen.modes, &buffer) orelse return false;
        self.typeBytes(bytes);
        return true;
    }

    /// Do what a key bound to an action does; true when it did something.
    /// A performable copy lets go of the selection, so the key's next press
    /// reaches the program.
    pub fn perform(self: *TerminalView, action: Action, performable: bool) bool {
        const s = &self.terminal.screen;
        switch (action) {
            .none => return false,
            .ignore => return true,
            .copy => {
                const copied = self.copy() catch |err| {
                    self.fail(err);
                    return false;
                };
                if (copied and performable) self.selection = null;
                return copied;
            },
            .paste => return self.paste() catch |err| {
                self.fail(err);
                return false;
            },
            .select_all => {
                self.selectAll();
                return true;
            },
            .clear_screen => return self.clearScreen(),
            .increase_font_size, .decrease_font_size, .reset_font_size => {
                self.zoom(switch (action) {
                    .increase_font_size => .{ .steps = 1 },
                    .decrease_font_size => .{ .steps = -1 },
                    else => .{ .reset = true },
                });
                return true;
            },
            .scroll_page_up, .scroll_page_down, .scroll_to_top, .scroll_to_bottom => {
                if (s.onAlternate()) return false;
                const page: isize = @intCast(@max(s.rows, 2) - 1);
                switch (action) {
                    .scroll_page_up => _ = s.scrollView(page),
                    .scroll_page_down => _ = s.scrollView(-page),
                    .scroll_to_top => _ = s.scrollView(@intCast(s.historyCount())),
                    else => _ = s.scrollViewToBottom(),
                }
                self.invalidate();
                return true;
            },
        }
    }

    fn mouseButton(button: z.PointerButton) input.MouseButton {
        return switch (button) {
            .primary => .left,
            .middle => .middle,
            .secondary => .right,
            else => .none,
        };
    }

    fn report(self: *TerminalView, button: input.MouseButton, action: input.MouseAction, point: z.Point, modifiers: z.KeyModifiers) bool {
        const at = self.cellAt(point);
        const pad = self.padding();
        const px = @max(0, (point.x - self.bounds.x - pad.x) * self.scale);
        const py = @max(0, (point.y - self.bounds.y - pad.y) * self.scale);
        var buffer: [input.max_mouse]u8 = undefined;
        const bytes = input.mouse(.{ .button = button, .action = action, .col = at.col, .row = at.row, .x = @intFromFloat(px), .y = @intFromFloat(py), .modifiers = modifiers }, self.terminal.screen.modes, &buffer) orelse return false;
        self.send(bytes) catch |err| self.fail(err);
        return true;
    }

    /// Whether the pointer goes to the program: it tracks the mouse and
    /// Shift is not held to select instead.
    fn tracking(self: *const TerminalView, modifiers: z.KeyModifiers) bool {
        return self.terminal.screen.modes.mouse != .none and !modifiers.shift;
    }

    fn pointerDown(self: *TerminalView, press: z.PointerButtonInput) bool {
        self.pointer = press.position;
        _ = self.trackScrollbar(press.position);
        // A press on the thumb holds it where it is pressed, and one on the
        // rest of the strip by its middle, which comes to the pointer.
        if (press.button == .primary and self.over_bar and self.reported_press == null) {
            const thumb = self.thumbOf(self.bounds.height);
            const y = press.position.y - self.bounds.y;
            self.bar_grab = if (y >= thumb.y and y < thumb.y + thumb.height) y - thumb.y else thumb.height / 2;
            self.bar_held = true;
            self.hover = null;
            self.dragScrollbar(press.position.y);
            self.invalidate();
            return true;
        }
        self.setLinkHeld(press.modifiers.control);
        // Ctrl over a link: a click opens it, before a program that takes
        // the mouse sees it.
        if (press.button == .primary and self.hover != null and self.reported_press == null) {
            self.openHovered();
            self.link_press = true;
            return true;
        }
        if (press.button == .secondary and self.options.right_click != .context_menu and !(self.tracking(press.modifiers))) {
            switch (self.options.right_click) {
                .context_menu => unreachable,
                .ignore => {},
                .copy => _ = self.perform(.copy, true),
                .copy_or_paste => if (!self.perform(.copy, true)) {
                    _ = self.perform(.paste, false);
                },
                .paste => {
                    self.selection = null;
                    _ = self.perform(.paste, false);
                },
            }
            return true;
        }
        if (self.tracking(press.modifiers)) {
            const button = mouseButton(press.button);
            if (self.report(button, .press, press.position, press.modifiers)) self.reported_press = button;
            return true;
        }
        if (press.button == .secondary) {
            self.notify(.{ .context_menu = press.position });
            return true;
        }
        if (press.button != .primary) return false;
        const s = &self.terminal.screen;
        const at = self.cellAt(press.position);
        const position: Position = .{ .row = s.viewRow(at.row), .col = at.col };
        const now = zio.milliTimestamp();
        const same = position.row == self.last_click_at.row and position.col == self.last_click_at.col;
        self.clicks = if (same and now - self.last_click < double_click_ms) @min(self.clicks + 1, 3) else 1;
        self.last_click = now;
        self.last_click_at = position;
        if (press.modifiers.shift and self.selection != null) {
            self.selection.?.head = position;
            self.selection.?.dragging = true;
            return true;
        }
        self.selection = .{ .anchor = position, .head = position, .unit = switch (self.clicks) {
            1 => .cell,
            2 => .word,
            else => .line,
        } };
        return true;
    }

    fn openHovered(self: *TerminalView) void {
        const hover = &(self.hover orelse return);
        const uri = hover.uri[0..hover.len];
        if (self.options.hooks.open_link) |hook| if (hook(self.options.hooks.context, uri, hover.path)) return;
        if (!hover.path) self.notify(.{ .open = uri });
    }

    fn pointerMove(self: *TerminalView, point: z.Point) bool {
        self.pointer = point;
        if (self.bar_held) {
            self.dragScrollbar(point.y);
            return true;
        }
        const bar_changed = self.trackScrollbar(point);
        if (self.link_press) return true;
        if (self.link_held) self.updateHover();
        if (self.reported_press) |button| {
            return self.report(button, .motion, point, .{});
        }
        if (self.terminal.screen.modes.mouse == .any) {
            if (self.cellAt(point).inside) return self.report(.none, .motion, point, .{});
        }
        const selection = &(self.selection orelse return bar_changed);
        if (!selection.dragging) return bar_changed;
        const s = &self.terminal.screen;
        // Dragging past the top or bottom scrolls the view.
        const cell = self.cellSize();
        const pad = self.padding();
        if (point.y < self.bounds.y + pad.y) {
            _ = s.scrollView(1);
        } else if (point.y > self.bounds.y + pad.y + @as(f32, @floatFromInt(s.rows)) * cell.height) _ = s.scrollView(-1);
        const at = self.cellAt(point);
        const head: Position = .{ .row = s.viewRow(at.row), .col = at.col };
        if (head.row == selection.head.row and head.col == selection.head.col) return false;
        selection.head = head;
        return true;
    }

    fn pointerUp(self: *TerminalView, press: z.PointerButtonInput) bool {
        if (self.bar_held and press.button == .primary) {
            self.bar_held = false;
            _ = self.trackScrollbar(press.position);
            self.invalidate();
            return true;
        }
        if (self.link_press) {
            self.link_press = false;
            return true;
        }
        if (self.reported_press) |button| {
            self.reported_press = null;
            _ = self.report(button, .release, press.position, press.modifiers);
            return true;
        }
        const selection = &(self.selection orelse return false);
        if (!selection.dragging) return false;
        selection.dragging = false;
        if (selection.empty()) {
            self.selection = null;
        } else if (self.options.copy_on_select) {
            _ = self.copyAs(.select) catch |err| self.fail(err);
        }
        return true;
    }

    fn scrollWheel(self: *TerminalView, position: z.Point, delta: f32, modifiers: z.KeyModifiers, precise: bool, momentum: bool) bool {
        const s = &self.terminal.screen;
        var zooming = modifiers.control;
        if (precise) {
            // A touchpad gesture keeps what it began as, even if Control
            // comes down while its momentum still runs.
            if (!momentum) self.scroll_zoom = zooming;
            zooming = self.scroll_zoom;
        }
        if (zooming) {
            // The wheel with Control held zooms, up larger.
            self.zoom_wheel -= delta;
            const steps: i32 = @intFromFloat(@trunc(self.zoom_wheel / wheel_notch));
            if (steps != 0) {
                self.zoom_wheel -= @as(f32, @floatFromInt(steps)) * wheel_notch;
                self.zoom(.{ .steps = steps });
            }
            return true;
        }
        self.wheel += delta / wheel_notch * self.notchRows();
        const lines: isize = @intFromFloat(@trunc(self.wheel));
        if (lines == 0) return true;
        self.wheel -= @floatFromInt(lines);
        const count: usize = @abs(lines);
        if (s.modes.mouse != .none and !modifiers.shift) {
            for (0..count) |_| _ = self.report(if (lines < 0) .wheel_up else .wheel_down, .press, position, .{});
            return true;
        }
        if (s.onAlternate() and s.modes.alternate_scroll) {
            const arrow = if (lines < 0) (if (s.modes.cursor_keys) "\x1bOA" else "\x1b[A") else (if (s.modes.cursor_keys) "\x1bOB" else "\x1b[B");
            for (0..count) |_| self.send(arrow) catch |err| self.fail(err);
            return true;
        }
        if (self.options.hooks.scroll) |hook| if (hook(self.options.hooks.context, lines)) return true;
        if (s.onAlternate()) return false;
        _ = s.scrollView(-lines);
        return true;
    }

    /// Rows a notch of the wheel scrolls.
    fn notchRows(self: *const TerminalView) f32 {
        if (self.options.scroll_lines) |lines| return @floatFromInt(lines);
        if (builtin.os.tag == .windows) {
            var lines: u32 = 3;
            if (win.SystemParametersInfoW(win.SPI_GETWHEELSCROLLLINES, 0, &lines, 0) != 0) {
                // "One screen at a time" scrolls a page.
                if (lines == win.WHEEL_PAGESCROLL) return @floatFromInt(@max(self.terminal.screen.rows, 2) - 1);
                return @floatFromInt(lines);
            }
        }
        return 3;
    }

    /// Ctrl, the link modifier, is held or let go of: the link under a
    /// still pointer follows.
    fn setLinkHeld(self: *TerminalView, held: bool) void {
        if (held == self.link_held) return;
        self.link_held = held;
        self.updateHover();
        self.invalidate();
    }

    /// The link under the pointer while Ctrl is held: none while the
    /// primary button selects or the program has a press.
    fn updateHover(self: *TerminalView) void {
        self.hover = null;
        if (!self.link_held or self.reported_press != null) return;
        if (self.selection) |s| if (s.dragging) return;
        const point = self.pointer orelse return;
        if (self.bar_held or self.overScrollbar(point)) return;
        const at = self.cellAt(point);
        if (!at.inside) return;
        const s = &self.terminal.screen;
        const position: Position = .{ .row = s.viewRow(at.row), .col = at.col };
        const line = s.rowAt(position.row) orelse return;
        if (at.col >= line.cells.len) return;
        const id = line.cells[at.col].style.link;
        if (id != 0) if (s.link(id)) |uri| {
            var start = at.col;
            while (start > 0 and line.cells[start - 1].style.link == id) start -= 1;
            var end = at.col + 1;
            while (end < line.cells.len and line.cells[end].style.link == id) end += 1;
            self.setHover(position.row, start, @intCast(end), uri, false);
            return;
        };
        var buffer: [2048]u8 = undefined;
        if (term.links.at(line.cells, at.col, &buffer)) |found| return self.setHover(position.row, found.start, found.end, found.uri, false);
        if (self.options.hooks.open_link != null) if (term.links.pathUnder(line.cells, at.col, &buffer)) |found| {
            self.setHover(position.row, found.start, found.end, found.uri, true);
        };
    }

    fn setHover(self: *TerminalView, row: u64, start: u16, end: u16, uri: []const u8, path: bool) void {
        self.hover = .{ .row = row, .start = start, .end = end, .path = path };
        const n = @min(uri.len, self.hover.?.uri.len);
        @memcpy(self.hover.?.uri[0..n], uri[0..n]);
        self.hover.?.len = n;
    }

    /// Hover over the leaf, outside the text field route, and key releases:
    /// the link Ctrl is held over is underlined.
    fn hoverInput(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        const before = self.hover;
        var bar_changed = false;
        switch (event) {
            .pointer_move => |local| {
                self.pointer = .{ .x = self.bounds.x + local.x, .y = self.bounds.y + local.y };
                bar_changed = self.trackScrollbar(self.pointer);
                self.updateHover();
            },
            .pointer_leave => {
                self.pointer = null;
                self.hover = null;
                bar_changed = self.trackScrollbar(null);
            },
            .key_up => |k| {
                if (k.key == .control) self.setLinkHeld(false);
                return false;
            },
            // Presses, drags, the wheel and keys go through the text field
            // route.
            .pointer_down, .pointer_drag, .pointer_up, .pointer_cancel, .wheel, .key => return false,
        }
        const was = before != null;
        const is = self.hover != null;
        return bar_changed or was != is or (was and is and (before.?.row != self.hover.?.row or before.?.start != self.hover.?.start));
    }
};

/// Whether the cell is one character in inverse video alone, as a
/// program draws its own cursor.
/// Where a placement draws: its whole image, scaled as the part it shows,
/// from its cell's corner, and the clip to that part within the grid.
fn imageRects(p: term.graphics.Placement, size: term.graphics.Layout, image: term.graphics.Image, corner: view.Point, scale: f32, grid: view.Rect) ?struct { whole: view.Rect, clip: view.Rect } {
    const at: view.Rect = .{
        .x = corner.x + @as(f32, @floatFromInt(p.x_offset)) / scale,
        .y = corner.y + @as(f32, @floatFromInt(p.y_offset)) / scale,
        .width = @as(f32, @floatFromInt(size.width)) / scale,
        .height = @as(f32, @floatFromInt(size.height)) / scale,
    };
    const clip = intersect(at, grid) orelse return null;
    const kx = at.width / @as(f32, @floatFromInt(size.src_w));
    const ky = at.height / @as(f32, @floatFromInt(size.src_h));
    return .{ .clip = clip, .whole = .{
        .x = at.x - @as(f32, @floatFromInt(size.src_x)) * kx,
        .y = at.y - @as(f32, @floatFromInt(size.src_y)) * ky,
        .width = @as(f32, @floatFromInt(image.width)) * kx,
        .height = @as(f32, @floatFromInt(image.height)) * ky,
    } };
}

fn intersect(a: view.Rect, b: view.Rect) ?view.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.width, b.x + b.width);
    const y1 = @min(a.y + a.height, b.y + b.height);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

/// An image's pixels, straight RGB or RGBA, as premultiplied BGRA, sampled
/// to `width` by `height`.
fn convertImage(image: term.graphics.Image, width: u32, height: u32, out: []u8) void {
    const bpp: usize = image.format.bytesPerPixel();
    for (0..height) |y| {
        const sy = y * image.height / height;
        for (0..width) |x| {
            const sx = x * image.width / width;
            const in = image.pixels[(sy * image.width + sx) * bpp ..][0..bpp];
            const a: u16 = if (bpp == 4) in[3] else 255;
            const o = out[(y * width + x) * 4 ..][0..4];
            o.* = .{ premultiply(in[2], a), premultiply(in[1], a), premultiply(in[0], a), @intCast(a) };
        }
    }
}

fn premultiply(c: u8, a: u16) u8 {
    return @intCast((@as(u16, c) * a + 127) / 255);
}

fn loneInverse(line: []const Cell, x: usize) bool {
    if (!line[x].style.attrs.inverse) return false;
    const before = x > 0 and line[x - 1].style.attrs.inverse;
    const after = x + 1 < line.len and line[x + 1].style.attrs.inverse;
    return !before and !after;
}

fn selectedAt(range: ?term.selection.Range, row: u64, col: usize) bool {
    const r = range orelse return false;
    return r.contains(.{ .row = row, .col = @intCast(@min(col, std.math.maxInt(u16))) });
}

fn blend(a: u24, b: u24) u24 {
    var out: u24 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const x: u32 = @as(u8, @truncate(a >> shift));
        const y: u32 = @as(u8, @truncate(b >> shift));
        out |= @as(u24, @intCast((x + y) / 2)) << shift;
    }
    return out;
}

/// Whether a key types text that comes after it, as text input.
fn typesText(k: z.KeyInput) bool {
    if (k.modifiers.control or k.modifiers.alt or k.modifiers.super) return false;
    return switch (k.key) {
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => true,
        .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9 => true,
        .space, .minus, .equal, .left_bracket, .right_bracket, .backslash, .semicolon, .apostrophe, .grave, .comma, .period, .slash => true,
        else => false,
    };
}

/// The nearest weight the UI's fonts have.
fn weightOf(weight: u16) ui.Font.Weight {
    if (weight < 450) return .regular;
    if (weight < 550) return .medium;
    if (weight < 650) return .semibold;
    return .bold;
}

fn darkColor(rgb: u24) bool {
    const r: u32 = @as(u8, @truncate(rgb >> 16));
    const g: u32 = @as(u8, @truncate(rgb >> 8));
    const b: u32 = @as(u8, @truncate(rgb));
    return 299 * r + 587 * g + 114 * b < 128 * 1000;
}

/// Shapes rather than text keep their colors under the minimum contrast:
/// box drawing, block elements, the legacy computing symbols and
/// Powerline's.
fn keepsColor(cp: u21) bool {
    return (cp >= 0x2500 and cp <= 0x259f) or (cp >= 0x1fb00 and cp <= 0x1fbff) or (cp >= 0xe0b0 and cp <= 0xe0d7);
}

/// `fg` with at least the WCAG contrast ratio with `bg`: itself when it
/// has it, else mixed toward black or white, whichever contrasts more
/// with `bg`, as little as reaches it.
pub fn contrasted(fg: u24, bg: u24, ratio: f32) u24 {
    const lb = luminance(bg);
    if (contrast(luminance(fg), lb) >= ratio) return fg;
    const to: u24 = if (contrast(1, lb) > contrast(0, lb)) 0xffffff else 0;
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..8) |_| {
        const mid = (lo + hi) / 2;
        if (contrast(luminance(term.theme.mix(fg, to, mid)), lb) >= ratio) hi = mid else lo = mid;
    }
    return term.theme.mix(fg, to, hi);
}

/// Relative luminance of an sRGB color, 0 for black to 1 for white.
pub fn luminance(rgb: u24) f32 {
    var out: f32 = 0;
    const weights = [3]f32{ 0.2126, 0.7152, 0.0722 };
    inline for (.{ 16, 8, 0 }, weights) |shift, weight| {
        const v: f32 = @as(f32, @floatFromInt(@as(u8, @truncate(rgb >> shift)))) / 255;
        const linear = if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
        out += weight * linear;
    }
    return out;
}

/// The contrast ratio of two luminances, from 1 to 21.
pub fn contrast(a: f32, b: f32) f32 {
    const hi = @max(a, b);
    const lo = @min(a, b);
    return (hi + 0.05) / (lo + 0.05);
}

test "grid size follows the bounds and the cell size" {
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 4 } });
    defer terminal.deinit();
    var tv = TerminalView.init(undefined, std.testing.allocator, &terminal, .{ .cell_width = 8, .cell_height = 16, .padding = .{ .x = 4, .y = 4 } });
    defer tv.deinit();
    const grid = tv.gridFor(.{ .x = 0, .y = 0, .width = 8 * 80 + 8 + 5, .height = 16 * 24 + 8 + 3 });
    try std.testing.expectEqual(@as(u16, 80), grid.cols);
    try std.testing.expectEqual(@as(u16, 24), grid.rows);
    tv.bounds = .{ .x = 100, .y = 50, .width = 8 * 10 + 8, .height = 16 * 4 + 8 };
    const at = tv.cellAt(.{ .x = 100 + 4 + 8 * 3 + 1, .y = 50 + 4 + 16 * 2 + 1 });
    try std.testing.expectEqual(@as(u16, 3), at.col);
    try std.testing.expectEqual(@as(u16, 2), at.row);
    try std.testing.expect(at.inside);
    try std.testing.expect(!tv.cellAt(.{ .x = 0, .y = 0 }).inside);
    try std.testing.expectEqual(@as(u24, 0x808080), blend(0xffffff, 0x010101));
}

const Sent = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    fn call(context: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Sent = @ptrCast(@alignCast(context.?));
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    fn text(self: *const Sent) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Board = struct {
    text: [64]u8 = undefined,
    len: usize = 0,
    fn read(context: ?*anyopaque, out: []u8) anyerror!usize {
        const self: *Board = @ptrCast(@alignCast(context.?));
        @memcpy(out[0..self.len], self.text[0..self.len]);
        return self.len;
    }
    fn write(context: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Board = @ptrCast(@alignCast(context.?));
        @memcpy(self.text[0..bytes.len], bytes);
        self.len = bytes.len;
    }
};

/// Notices, recorded.
const Seen = struct {
    opened: [64]u8 = undefined,
    opened_len: usize = 0,
    menus: usize = 0,
    copies: usize = 0,
    last_source: ?CopySource = null,
    search: SearchStatus = .{},
    fn call(context: ?*anyopaque, notice: Notice) void {
        const self: *Seen = @ptrCast(@alignCast(context.?));
        switch (notice) {
            .open => |uri| {
                @memcpy(self.opened[0..uri.len], uri);
                self.opened_len = uri.len;
            },
            .context_menu => self.menus += 1,
            .copied => |c| {
                self.copies += 1;
                self.last_source = c.source;
            },
            .search => |s| self.search = .{ .total = s.total, .selected = s.selected },
            else => {},
        }
    }
};

fn testView(host: *view.Host, terminal: *term.Terminal, sent: *Sent, board: *Board, options: Options) TerminalView {
    var with = options;
    with.cell_width = 10;
    with.cell_height = 20;
    with.padding = .{ .x = -1, .y = -1 };
    with.send = .{ .context = sent, .call = Sent.call };
    with.clipboard = .{ .context = board, .read = Board.read, .write = Board.write };
    var tv = TerminalView.init(host, std.testing.allocator, terminal, with);
    // The tests press the Linux and Windows keys on every host; keybind.zig
    // covers the macOS defaults.
    tv.bindings = .init(.linux, with.keybinds, with.no_default_keybinds);
    tv.bounds = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    return tv;
}

const Empty = struct {
    fn build(_: *u8, _: *view.View) anyerror!void {}
};

test "keys, text, pastes and replies reach the program" {
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 4 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    var tv = testView(&host, &terminal, &sent, &board, .{});
    defer tv.deinit();
    tv.bind();
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .up } }));
    try std.testing.expect(!tv.handle(.{ .key_input = .{ .key = .a } }));
    try std.testing.expect(tv.handle(.{ .text_input = .{ .text = "ä", .producer = .application } }));
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .c, .modifiers = .{ .control = true } } }));
    tv.feed("\x1b[?1h\x1b[?2004h\x1b[6n");
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .up } }));
    try std.testing.expect(tv.handle(.{ .edit_key = .{ .key = .left } }));
    board.len = 3;
    @memcpy(board.text[0..3], "a\nb");
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .v, .modifiers = .{ .control = true, .shift = true } } }));
    try std.testing.expectEqualStrings("\x1b[Aä\x03\x1b[1;1R\x1bOA\x1bOD\x1b[200~a\rb\x1b[201~", sent.text());
    try std.testing.expect(tv.last_error == null);

    // Composition shows at the cursor until it is committed or cancelled.
    try std.testing.expect(tv.handle(.{ .text_preedit = .{ .text = "zh", .selection_start = 2, .selection_end = 2 } }));
    try std.testing.expectEqual(@as(usize, 2), tv.preedit_len);
    try std.testing.expect(tv.handle(.text_preedit_cancel));
    try std.testing.expectEqual(@as(usize, 0), tv.preedit_len);
}

test "the pointer selects and copies, and reports when the program tracks it" {
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 4 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    // Control+C copies a selection, and interrupts without one.
    var tv = testView(&host, &terminal, &sent, &board, .{ .keybinds = &.{.{ .mods = .{ .control = true }, .key = .c, .action = .copy, .performable = true }} });
    defer tv.deinit();
    tv.bind();
    tv.feed("hello you\r\nsecond");
    // Drag from 'e' to 'y' of the first line.
    try std.testing.expect(tv.handle(.{ .pointer_down = .{ .position = .{ .x = 15, .y = 5 } } }));
    try std.testing.expect(tv.handle(.{ .pointer_move = .{ .x = 65, .y = 5 } }));
    try std.testing.expect(tv.handle(.{ .pointer_up = .{ .position = .{ .x = 65, .y = 5 } } }));
    try std.testing.expect(try tv.copy());
    try std.testing.expectEqualStrings("ello y", board.text[0..board.len]);
    board.len = 0;
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .c, .modifiers = .{ .control = true } } }));
    try std.testing.expectEqualStrings("ello y", board.text[0..board.len]);
    try std.testing.expect(tv.selection == null);
    try std.testing.expectEqual(@as(usize, 0), sent.len);
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .c, .modifiers = .{ .control = true } } }));
    try std.testing.expectEqualStrings("\x03", sent.text());
    sent.len = 0;
    // A double click selects a word.
    try std.testing.expect(tv.handle(.{ .pointer_down = .{ .position = .{ .x = 25, .y = 25 } } }));
    try std.testing.expect(tv.handle(.{ .pointer_up = .{ .position = .{ .x = 25, .y = 25 } } }));
    try std.testing.expect(tv.handle(.{ .pointer_down = .{ .position = .{ .x = 25, .y = 25 } } }));
    try std.testing.expect(tv.handle(.{ .pointer_up = .{ .position = .{ .x = 25, .y = 25 } } }));
    const word = (try tv.selectedText(std.testing.allocator)).?;
    defer std.testing.allocator.free(word);
    try std.testing.expectEqualStrings("second", word);

    tv.feed("\x1b[?1000h\x1b[?1006h");
    try std.testing.expect(tv.handle(.{ .pointer_down = .{ .position = .{ .x = 35, .y = 45 } } }));
    try std.testing.expect(tv.handle(.{ .pointer_up = .{ .position = .{ .x = 35, .y = 45 } } }));
    try std.testing.expect(tv.handle(.{ .wheel = .{ .position = .{ .x = 35, .y = 45 }, .delta = .{ .x = 0, .y = -48 } } }));
    try std.testing.expectEqualStrings("\x1b[<0;4;3M\x1b[<0;4;3m\x1b[<64;4;3M\x1b[<64;4;3M\x1b[<64;4;3M", sent.text());
}

test "the wheel scrolls the scrollback, or sends arrows on the alternate screen" {
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 2 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    var tv = testView(&host, &terminal, &sent, &board, .{});
    defer tv.deinit();
    tv.bind();
    tv.feed("1\r\n2\r\n3\r\n4\r\n5");
    try std.testing.expect(tv.handle(.{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .x = 0, .y = -16 } } }));
    try std.testing.expectEqual(@as(usize, 1), terminal.screen.viewportOffset());
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .page_up, .modifiers = .{ .shift = true } } }));
    try std.testing.expectEqual(@as(usize, 2), terminal.screen.viewportOffset());
    // Typing returns to the bottom.
    try std.testing.expect(tv.handle(.{ .text_input = .{ .text = "x", .producer = .application } }));
    try std.testing.expectEqual(@as(usize, 0), terminal.screen.viewportOffset());
    sent.len = 0;
    tv.feed("\x1b[?1049h");
    try std.testing.expect(tv.handle(.{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .x = 0, .y = -48 } } }));
    try std.testing.expectEqualStrings("\x1b[A\x1b[A\x1b[A", sent.text());
    sent.len = 0;
    // Scrolling keys are performable: a full-screen program gets them.
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .page_up, .modifiers = .{ .shift = true } } }));
    try std.testing.expectEqualStrings("\x1b[5;2~", sent.text());
}

test "bindings, hooks, zoom and the user's clear" {
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 3, .scrollback = 50 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    const Hook = struct {
        fn key(_: ?*anyopaque, k: z.KeyInput) bool {
            return k.key == .f5;
        }
    };
    var tv = testView(&host, &terminal, &sent, &board, .{
        .font = .{ .size = 10 },
        .keybinds = &.{
            .{ .mods = .{ .control = true, .shift = true }, .key = .a, .action = .none },
            .{ .key = .f6, .action = .ignore },
        },
        .hooks = .{ .key = Hook.key },
    });
    defer tv.deinit();
    tv.bind();
    // The hook and ignore take keys and the text they type.
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .f5 } }));
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .f6 } }));
    try std.testing.expect(tv.handle(.{ .text_input = .{ .text = "x", .producer = .application } }));
    try std.testing.expectEqualStrings("x", sent.text());
    sent.len = 0;
    tv.options.keybinds = &.{};
    tv.bindings.bind(.{ .key = .q, .action = .ignore });
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .q } }));
    try std.testing.expect(tv.handle(.{ .text_input = .{ .text = "q", .producer = .application } }));
    try std.testing.expectEqual(@as(usize, 0), sent.len);
    // Unbound, Control+Shift+A goes to the program.
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .a, .modifiers = .{ .control = true, .shift = true } } }));
    try std.testing.expectEqualStrings("\x01", sent.text());
    // Zoom by keys and by the wheel with Control held.
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .equal, .modifiers = .{ .control = true } } }));
    try std.testing.expectEqual(@as(f32, 11), tv.fontSize());
    try std.testing.expectEqual(@as(f32, 11), tv.cellSize().width);
    _ = tv.handle(.{ .key_input = .{ .key = .control, .modifiers = .{ .control = true } } });
    try std.testing.expect(tv.handle(.{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .x = 0, .y = 96 } } }));
    try std.testing.expectEqual(@as(f32, 9), tv.fontSize());
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .digit0, .modifiers = .{ .control = true } } }));
    try std.testing.expectEqual(@as(f32, 10), tv.fontSize());
    // Clear keeps the cursor's line at the top.
    tv.feed("a\r\nb\r\nc\r\nd\r\n$ ");
    try std.testing.expect(terminal.screen.historyCount() > 0);
    try std.testing.expect(tv.clearScreen());
    try std.testing.expectEqual(@as(usize, 0), terminal.screen.historyCount());
    try std.testing.expectEqual(@as(u21, '$'), terminal.screen.row(0)[0].cp);
    // The context menu shows the keys of its items.
    const menu = tv.contextMenu();
    try std.testing.expect(!menu[0].enabled);
    try std.testing.expectEqual(z.KeyCode.c, menu[0].shortcut.?.key);
    try std.testing.expect(menu[3].separator_before);
    try std.testing.expect(menu[3].enabled);
}

test "secondary clicks, links and copies" {
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 20, .rows = 4 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    var seen: Seen = .{};
    var tv = testView(&host, &terminal, &sent, &board, .{ .notify = .{ .context = &seen, .call = Seen.call }, .right_click = .copy_or_paste });
    tv.bounds.width = 200;
    defer tv.deinit();
    tv.bind();
    tv.feed("x.io http://a.b/c");
    // No selection: the secondary click pastes.
    board.len = 2;
    @memcpy(board.text[0..2], "hi");
    try std.testing.expect(tv.handle(.{ .pointer_down = .{ .position = .{ .x = 5, .y = 5 }, .button = .secondary } }));
    try std.testing.expectEqualStrings("hi", sent.text());
    // With one, it copies and lets go of it.
    tv.selectAll();
    try std.testing.expect(tv.handle(.{ .pointer_down = .{ .position = .{ .x = 5, .y = 5 }, .button = .secondary } }));
    try std.testing.expect(tv.selection == null);
    try std.testing.expectEqual(@as(?CopySource, .user), seen.last_source);
    tv.options.right_click = .context_menu;
    try std.testing.expect(tv.handle(.{ .pointer_down = .{ .position = .{ .x = 5, .y = 5 }, .button = .secondary } }));
    try std.testing.expectEqual(@as(usize, 1), seen.menus);

    // Over a link, Ctrl shows it and a click opens it.
    try std.testing.expect(!tv.handle(.{ .pointer_move = .{ .x = 75, .y = 5 } }));
    try std.testing.expect(tv.hoveredLink() == null);
    _ = tv.handle(.{ .key_input = .{ .key = .control, .modifiers = .{ .control = true } } });
    const link = tv.hoveredLink().?;
    try std.testing.expectEqualStrings("http://a.b/c", link.uri);
    try std.testing.expect(!link.path);
    try std.testing.expectEqual(@as(f32, 50), link.rect.x);
    try std.testing.expect(tv.pointerShape(false) == .link);
    try std.testing.expect(tv.handle(.{ .pointer_down = .{ .position = .{ .x = 75, .y = 5 }, .modifiers = .{ .control = true } } }));
    try std.testing.expect(tv.handle(.{ .pointer_up = .{ .position = .{ .x = 75, .y = 5 } } }));
    try std.testing.expectEqualStrings("http://a.b/c", seen.opened[0..seen.opened_len]);
    try std.testing.expect(tv.selection == null);
    // Paths are links only for an app that opens them.
    _ = tv.handle(.{ .pointer_move = .{ .x = 15, .y = 5 } });
    try std.testing.expect(tv.hoveredLink() == null);
    _ = TerminalView.hoverInput(&tv, 0, .{ .key_up = .{ .key = .control } });
    try std.testing.expect(!tv.link_held);
    try std.testing.expect(tv.pointerShape(false) == .text);
    tv.feed("\x1b[?1000h");
    try std.testing.expect(tv.pointerShape(false) == .arrow);
    try std.testing.expect(tv.pointerShape(true) == .text);
}

test "search highlights matches and tells how it goes" {
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 2, .scrollback = 50 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    var seen: Seen = .{};
    var tv = testView(&host, &terminal, &sent, &board, .{ .notify = .{ .context = &seen, .call = Seen.call } });
    defer tv.deinit();
    tv.bind();
    tv.feed("Foo\r\nbar\r\nfoo\r\nbaz");
    try tv.startSearch("foo");
    try std.testing.expectEqual(@as(usize, 2), seen.search.total);
    try std.testing.expectEqual(@as(usize, 1), seen.search.selected);
    const th = tv.theme();
    const row = terminal.screen.firstRow();
    try std.testing.expectEqual(th.searchColors().match, tv.colorsOf(terminal.screen.rowAt(row).?.cells[0], false, tv.foundAt(row, 0)).bg);
    tv.searchNext();
    try std.testing.expectEqual(@as(usize, 2), seen.search.selected);
    // The match in the scrollback scrolled into view.
    try std.testing.expect(terminal.screen.viewportOffset() > 0);
    // New output is searched as it comes.
    tv.feed("\r\nfoo");
    try std.testing.expect(tv.searchStale());
    tv.refreshSearch();
    try std.testing.expectEqual(@as(usize, 3), seen.search.total);
    tv.endSearch();
    try std.testing.expectEqual(@as(usize, 0), seen.search.total);
}

test "themes follow the window, and contrast keeps text readable" {
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 2 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    const mocha = term.theme.builtinTheme("Catppuccin Mocha").?;
    var tv = testView(&host, &terminal, &sent, &board, .{ .dark_theme = mocha });
    defer tv.deinit();
    tv.bind();
    _ = TerminalView.measure(&tv, ui.Theme.light());
    try std.testing.expectEqual(term.theme.light.background, terminal.background);
    _ = TerminalView.measure(&tv, ui.Theme.dark());
    try std.testing.expectEqual(mocha.background, terminal.background);
    try std.testing.expectEqual(mocha.palette[1], terminal.palette[1]);
    tv.setTheme(term.theme.dark, null);
    try std.testing.expectEqual(term.theme.dark.background, terminal.background);

    // Light gray on white darkens to the ratio, keeping its hue's place.
    const gray = contrasted(0xdddddd, 0xffffff, 4.5);
    try std.testing.expect(contrast(luminance(gray), luminance(0xffffff)) >= 4.5);
    try std.testing.expectEqual(@as(u24, 0), contrasted(0x646464, 0x808080, 21));
    try std.testing.expectEqual(@as(u24, 0), contrasted(0, 0xffffff, 4.5));
    tv.setMinimumContrast(3);
    tv.setTheme(term.theme.light, null);
    tv.feed("\x1b[93mA\xe2\x96\x88");
    const cells = terminal.screen.row(0);
    const fg = tv.colorsOf(cells[0], false, .none).fg;
    try std.testing.expect(contrast(luminance(fg), luminance(0xffffff)) >= 3);
    try std.testing.expectEqual(term.theme.light.palette[11], tv.colorsOf(cells[1], false, .none).fg);
}

test "images draw scaled into their cells, clipped to their part and the grid" {
    var pixels = [_]u8{ 255, 0, 0, 128, 0, 255, 0, 255, 0, 0, 255, 0, 9, 9, 9, 255 };
    const image: term.graphics.Image = .{ .id = 1, .width = 2, .height = 2, .format = .rgba, .pixels = &pixels };
    var out: [16]u8 = undefined;
    convertImage(image, 2, 2, &out);
    // Premultiplied BGRA.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 128, 128, 0, 255, 0, 255, 0, 0, 0, 0, 9, 9, 9, 255 }, &out);
    var small: [4]u8 = undefined;
    convertImage(image, 1, 1, &small);
    try std.testing.expectEqualSlices(u8, out[0..4], &small);

    // The right column of the image over two cells of 10 by 20, at scale 2.
    const p: term.graphics.Placement = .{ .image_id = 1, .id = 1, .row = 0, .col = 0, .src_x = 1, .cols = 2, .rows = 1 };
    const size = term.graphics.layout(p, image, 20, 40);
    const grid: view.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const rects = imageRects(p, size, image, .{ .x = 30, .y = 40 }, 2, grid).?;
    try std.testing.expectEqual(view.Rect{ .x = 30, .y = 40, .width = 20, .height = 20 }, rects.clip);
    try std.testing.expectEqual(view.Rect{ .x = 10, .y = 40, .width = 40, .height = 20 }, rects.whole);
    // Out of the grid, nothing.
    try std.testing.expect(imageRects(p, size, image, .{ .x = 100, .y = 0 }, 2, grid) == null);
    try std.testing.expectEqual(TerminalView.ImageLayer.below_background, TerminalView.layerOf(-(1 << 30) - 1));
    try std.testing.expectEqual(TerminalView.ImageLayer.below_text, TerminalView.layerOf(-1));
    try std.testing.expectEqual(TerminalView.ImageLayer.above_text, TerminalView.layerOf(0));
}

test "a selection follows its text as a new width rewraps the screen" {
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 8, .rows = 3 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    var tv = testView(&host, &terminal, &sent, &board, .{ .resize_by_conn = true });
    defer tv.deinit();
    tv.feed("abcdefghij");
    // "ij", on the wrapped row.
    tv.selection = .{ .anchor = .{ .row = terminal.screen.screenRow(1), .col = 0 }, .head = .{ .row = terminal.screen.screenRow(1), .col = 1 }, .dragging = false };
    try tv.resize(12, 3);
    const text = (try tv.selectedText(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ij", text);
}

test "a terminal shown from a server tells its stream the theme, and resizes when told" {
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 2 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    const Stream = struct {
        background: u24 = 0,
        fn theme(context: ?*anyopaque, t: Theme) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.background = t.background;
        }
    };
    var stream: Stream = .{};
    var tv = testView(&host, &terminal, &sent, &board, .{ .conn = .{ .context = &stream, .theme = Stream.theme }, .resize_by_conn = true, .theme = term.theme.light });
    defer tv.deinit();
    tv.bind();
    try std.testing.expectEqual(term.theme.light.background, stream.background);
    try tv.resize(12, 3);
    try std.testing.expectEqual(@as(u16, 12), terminal.screen.cols);
    try std.testing.expectEqual(@as(u16, 3), terminal.screen.rows);
}

test {
    std.testing.refAllDecls(TerminalView);
    _ = box;
}

test "the scroll bar shows as the viewport moves, fades, and drags the scrollback" {
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 4, .scrollback = 100 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    var tv = testView(&host, &terminal, &sent, &board, .{});
    defer tv.deinit();
    tv.bind();
    const ms = std.time.ns_per_ms;
    // No scrollback, no bar.
    try std.testing.expect(tv.scrollbarShown(1000 * ms, 0).alpha == null);
    try std.testing.expect(!tv.overScrollbar(.{ .x = 95, .y = 40 }));
    for (0..20) |_| tv.feed("line\r\n");
    try std.testing.expect(tv.scrollbarShown(1000 * ms, 0).alpha == null);
    // The viewport moves: the bar shows, lingers, then fades out.
    try std.testing.expect(tv.handle(.{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .x = 0, .y = -48 } } }));
    const moved = tv.scrollbarShown(2000 * ms, terminal.screen.viewportOffset());
    try std.testing.expectEqual(@as(?f32, 1), moved.alpha);
    try std.testing.expectEqual(@as(?u64, 3000 * ms), moved.wake);
    const fading = tv.scrollbarShown(3150 * ms, terminal.screen.viewportOffset());
    try std.testing.expect(fading.alpha.? > 0.4 and fading.alpha.? < 0.6);
    try std.testing.expectEqual(@as(?u64, 3166 * ms), fading.wake);
    try std.testing.expect(tv.scrollbarShown(3400 * ms, terminal.screen.viewportOffset()).alpha == null);
    // Over its strip it shows, wide, with the arrow, and links do not.
    try std.testing.expect(tv.handle(.{ .pointer_move = .{ .x = 95, .y = 40 } }));
    try std.testing.expect(tv.over_bar);
    try std.testing.expectEqual(PointerShape.arrow, tv.pointerShape(false));
    try std.testing.expectEqual(@as(?f32, 1), tv.scrollbarShown(5000 * ms, terminal.screen.viewportOffset()).alpha);
    // A press at the top of the track drags to the oldest rows, at the
    // bottom to the newest.
    try std.testing.expect(tv.handle(.{ .pointer_down = .{ .position = .{ .x = 95, .y = 0 } } }));
    try std.testing.expect(tv.bar_held);
    try std.testing.expectEqual(terminal.screen.historyCount(), terminal.screen.viewportOffset());
    try std.testing.expect(tv.handle(.{ .pointer_move = .{ .x = 40, .y = 79 } }));
    try std.testing.expectEqual(@as(usize, 0), terminal.screen.viewportOffset());
    try std.testing.expect(tv.selection == null);
    try std.testing.expect(tv.handle(.{ .pointer_up = .{ .position = .{ .x = 40, .y = 79 } } }));
    try std.testing.expect(!tv.bar_held and !tv.over_bar);
    try std.testing.expect(sent.len == 0);
}

test "a touchpad's momentum does not turn its scroll into a zoom" {
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 2, .scrollback = 100 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    var tv = testView(&host, &terminal, &sent, &board, .{ .font = .{ .size = 12 } });
    defer tv.deinit();
    tv.bind();
    for (0..20) |_| tv.feed("line\r\n");
    try std.testing.expect(tv.handle(.{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .x = 0, .y = -48 }, .precise = true } }));
    try std.testing.expectEqual(@as(usize, 3), terminal.screen.viewportOffset());
    // Control comes down while the momentum runs: it still scrolls.
    _ = tv.handle(.{ .key_input = .{ .key = .control, .modifiers = .{ .control = true } } });
    try std.testing.expect(tv.handle(.{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .x = 0, .y = -48 }, .precise = true, .momentum = true } }));
    try std.testing.expectEqual(@as(usize, 6), terminal.screen.viewportOffset());
    try std.testing.expectEqual(@as(f32, 12), tv.fontSize());
    // A new gesture with Control held zooms.
    try std.testing.expect(tv.handle(.{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .x = 0, .y = -48 }, .precise = true } }));
    try std.testing.expectEqual(@as(f32, 13), tv.fontSize());
}
