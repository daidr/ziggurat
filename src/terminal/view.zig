//! A terminal as a leaf of declarative views. The leaf paints the screen's
//! cells with the frame's rectangles and monospace labels, sizes the grid
//! to its bounds, and takes the keyboard, typed and composed text, the
//! pointer and the wheel as a text field of the UI Context, so input
//! methods compose into it like any text box. Keys become escape
//! sequences, the pointer selects text or, when the program asks, reports
//! to it, and links open on Ctrl+click.
//!
//! Resizing and registering with the Context run as tasks posted after
//! paint, never inside it, and an unchanged terminal paints without
//! allocating. The window's Context needs `prepareTextFields` before the
//! leaf is shown.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const term = @import("ziggurat_terminal");

const Screen = term.Screen;
const Cell = term.Cell;
const Position = term.Position;
const input = term.input;

/// Reads and writes the clipboard for copy, paste and allowed OSC 52
/// requests.
pub const Clipboard = struct {
    context: ?*anyopaque = null,
    /// Write clipboard text into the buffer and return its length.
    read: *const fn (?*anyopaque, []u8) anyerror!usize,
    write: *const fn (?*anyopaque, []const u8) anyerror!void,
};

/// Bytes for the program, for a terminal without a `Session`.
pub const Send = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, []const u8) anyerror!void,
};

pub const Notice = union(enum) {
    bell,
    title: []const u8,
    directory: []const u8,
    /// The program ended; the screen stays until the view is released.
    exited: term.Exit,
    /// The user Ctrl+clicked a link.
    open: []const u8,
};

pub const Notify = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, Notice) void,
};

pub const Options = struct {
    /// Accessible name.
    name: []const u8 = "Terminal",
    font_size: f32 = 14,
    /// Cell size in DIPs; 0 measures the font with `measurer`.
    cell_width: f32 = 0,
    cell_height: f32 = 0,
    padding: f32 = 4,
    measurer: view.Measurer = .{},
    /// Grid size preferred before the parent's flex layout applies.
    cols: u16 = 80,
    rows: u16 = 24,
    clipboard: ?Clipboard = null,
    send: ?Send = null,
    notify: ?Notify = null,
    selection_color: u24 = 0x264f78,
    /// Copy whenever a selection ends.
    copy_on_select: bool = false,
    /// Lines per wheel notch.
    scroll_lines: u16 = 3,
    /// Largest paste, in bytes.
    paste_bytes: usize = 64 * 1024,
};

pub const max_value = 512;
const max_preedit = 256;
const wheel_notch: f32 = 48;
const double_click_ms = 500;

pub const TerminalView = struct {
    host: *view.Host,
    allocator: std.mem.Allocator,
    terminal: *term.Terminal,
    session: ?*term.Session = null,
    options: Options,
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
    /// A press the program is tracking, by button.
    reported_press: ?input.MouseButton = null,
    last_click: i64 = 0,
    last_click_at: Position = .{ .row = 0, .col = 0 },
    clicks: u8 = 0,
    wheel: f32 = 0,
    exit: ?term.Exit = null,
    /// The first error from deferred work or input, for diagnostics.
    last_error: ?anyerror = null,
    value: [max_value]u8 = undefined,

    const Hover = struct { row: u64, start: u16, end: u16, uri: [term.screen.Links.max_uri]u8 = undefined, len: usize = 0 };

    /// The view takes the terminal's event handler. Keep both at stable
    /// addresses while the view is shown and until `detach`.
    pub fn init(host: *view.Host, allocator: std.mem.Allocator, terminal: *term.Terminal, options: Options) TerminalView {
        return .{ .host = host, .allocator = allocator, .terminal = terminal, .options = options };
    }

    /// Route the terminal's events here. Call once the view is at its
    /// final address.
    pub fn bind(self: *TerminalView) void {
        self.terminal.options.handler = .{ .context = self, .call = handleEvent };
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
            .clipboard_write => |text| if (self.options.clipboard) |clipboard| clipboard.write(clipboard.context, text) catch |err| self.fail(err),
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

    /// Paste from the clipboard.
    pub fn paste(self: *TerminalView) !void {
        const clipboard = self.options.clipboard orelse return error.ClipboardUnavailable;
        const buffer = try self.allocator.alloc(u8, self.options.paste_bytes);
        defer self.allocator.free(buffer);
        const n = try clipboard.read(clipboard.context, buffer);
        if (n > buffer.len) return error.PasteTooLarge;
        if (!std.unicode.utf8ValidateSlice(buffer[0..n])) return error.InvalidUtf8;
        try self.pasteText(buffer[0..n]);
    }

    /// The selected text, allocated, or null without a selection.
    pub fn selectedText(self: *TerminalView, allocator: std.mem.Allocator) !?[]u8 {
        const selection = self.selection orelse return null;
        if (selection.empty()) return null;
        return try term.selection.text(&self.terminal.screen, selection.range(&self.terminal.screen), allocator);
    }

    /// Copy the selection to the clipboard; false without one.
    pub fn copy(self: *TerminalView) !bool {
        const clipboard = self.options.clipboard orelse return error.ClipboardUnavailable;
        const text = try self.selectedText(self.allocator) orelse return false;
        defer self.allocator.free(text);
        try clipboard.write(clipboard.context, text);
        return true;
    }

    /// Select everything in the scrollback and on screen.
    pub fn selectAll(self: *TerminalView) void {
        const s = &self.terminal.screen;
        self.selection = .{ .anchor = .{ .row = s.firstRow(), .col = 0 }, .head = .{ .row = s.screenRow(s.rows - 1), .col = s.cols - 1 }, .dragging = false };
        self.invalidate();
    }

    pub fn clearSelection(self: *TerminalView) void {
        self.selection = null;
        self.invalidate();
    }

    // ---- Geometry --------------------------------------------------------

    fn font(self: *const TerminalView) ui.Font {
        return .{ .size = self.options.font_size, .monospace = true };
    }
    pub fn cellSize(self: *const TerminalView) struct { width: f32, height: f32 } {
        const sample = "0123456789";
        const w = if (self.options.cell_width > 0) self.options.cell_width else self.options.measurer.textSize(sample, self.font()).width / sample.len;
        const h = if (self.options.cell_height > 0) self.options.cell_height else @ceil(self.options.font_size * 1.3);
        return .{ .width = @max(w, 1), .height = @max(h, 1) };
    }

    /// The grid that fits `bounds`.
    pub fn gridFor(self: *const TerminalView, bounds: view.Rect) term.Size {
        const cell = self.cellSize();
        const pad = self.options.padding;
        const cols: u16 = @intFromFloat(std.math.clamp(@floor((bounds.width - 2 * pad) / cell.width), 2, 1000));
        const rows: u16 = @intFromFloat(std.math.clamp(@floor((bounds.height - 2 * pad) / cell.height), 1, 1000));
        return .{ .cols = cols, .rows = rows, .width = @intFromFloat(@round(@as(f32, @floatFromInt(cols)) * cell.width * self.scale)), .height = @intFromFloat(@round(@as(f32, @floatFromInt(rows)) * cell.height * self.scale)) };
    }

    /// The view row and column under a window point, clamped to the grid.
    fn cellAt(self: *const TerminalView, point: z.Point) struct { col: u16, row: u16, inside: bool } {
        const cell = self.cellSize();
        const s = &self.terminal.screen;
        const x = (point.x - self.bounds.x - self.options.padding) / cell.width;
        const y = (point.y - self.bounds.y - self.options.padding) / cell.height;
        const inside = x >= 0 and y >= 0 and x < @as(f32, @floatFromInt(s.cols)) and y < @as(f32, @floatFromInt(s.rows));
        return .{
            .col = @intFromFloat(std.math.clamp(@floor(x), 0, @as(f32, @floatFromInt(s.cols - 1)))),
            .row = @intFromFloat(std.math.clamp(@floor(y), 0, @as(f32, @floatFromInt(s.rows - 1)))),
            .inside = inside,
        };
    }

    fn measure(ptr: *anyopaque, _: ui.Theme) view.layout.Measurement {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        const cell = self.cellSize();
        const pad = 2 * self.options.padding;
        return .{
            .minimum = .{ .width = 4 * cell.width + pad, .height = cell.height + pad },
            .preferred = .{ .width = @as(f32, @floatFromInt(self.options.cols)) * cell.width + pad, .height = @as(f32, @floatFromInt(self.options.rows)) * cell.height + pad },
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
        const resize = if (self.applied) |applied| !std.meta.eql(applied, grid) else true;
        if (resize) self.wanted = grid;
        const caret_moved = self.client != null and !std.meta.eql(self.caret, self.caret_sent);
        if (self.queued or (!resize and self.token != null and !caret_moved)) return;
        const window = self.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = run }) catch |err| return self.fail(err);
        self.queued = true;
    }

    /// Posted after paint: resize, register for input, place the input
    /// method's caret.
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
            if (grid.cols != s.cols or grid.rows != s.rows) {
                if (s.resize(grid.cols, grid.rows)) {
                    self.selection = null;
                } else |err| self.fail(err);
            }
            if (self.session) |session| session.resize(grid);
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
    }

    // ---- Paint -----------------------------------------------------------

    const Colors = struct { fg: u24, bg: u24 };

    fn colorsOf(self: *const TerminalView, cell: Cell, selected: bool) Colors {
        const t = self.terminal;
        const style = cell.style;
        var fg = t.rgb(style.fg, true);
        var bg = t.rgb(style.bg, false);
        if (style.attrs.dim) fg = blend(fg, bg);
        if (style.attrs.inverse) std.mem.swap(u24, &fg, &bg);
        if (t.screen.modes.reverse_video) std.mem.swap(u24, &fg, &bg);
        if (selected) bg = self.options.selection_color;
        if (style.attrs.hidden) fg = bg;
        return .{ .fg = fg, .bg = bg };
    }

    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: view.Rect) anyerror!void {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        self.bounds = bounds;
        self.scale = frame.size.scale;
        const t = self.terminal;
        const s = &t.screen;
        const cell = self.cellSize();
        const pad = self.options.padding;
        const ox = bounds.x + pad;
        const oy = bounds.y + pad;
        const background = if (s.modes.reverse_video) t.foreground else t.background;
        frame.rect(bounds, background);
        try frame.pushClip(bounds);
        const range = if (self.selection) |selection| (if (selection.empty()) null else selection.range(s)) else null;
        const offset = s.viewportOffset();
        for (0..s.rows) |y| {
            const abs = s.viewRow(y);
            const line = s.rowAt(abs) orelse continue;
            const top = oy + @as(f32, @floatFromInt(y)) * cell.height;
            // Backgrounds, merged across cells of one color.
            var x: usize = 0;
            while (x < line.cells.len) {
                const bg = self.colorsOf(line.cells[x], selectedAt(range, abs, x)).bg;
                var end = x + 1;
                while (end < line.cells.len and self.colorsOf(line.cells[end], selectedAt(range, abs, end)).bg == bg) end += 1;
                if (bg != background) frame.rect(.{ .x = ox + @as(f32, @floatFromInt(x)) * cell.width, .y = top, .width = @as(f32, @floatFromInt(end - x)) * cell.width, .height = cell.height }, bg);
                x = end;
            }
            // Selection past the end of a short scrollback line.
            if (range) |r| if (line.cells.len < s.cols and selectedAt(r, abs, line.cells.len)) {
                frame.rect(.{ .x = ox + @as(f32, @floatFromInt(line.cells.len)) * cell.width, .y = top, .width = @as(f32, @floatFromInt(s.cols - line.cells.len)) * cell.width, .height = cell.height }, self.options.selection_color);
            };
            self.paintText(frame, line.cells, abs, range, ox, top, cell.width, cell.height);
            if (self.hover) |hover| if (hover.row == abs and hover.start < line.cells.len) {
                const fg = self.colorsOf(line.cells[hover.start], false).fg;
                frame.rect(.{ .x = ox + @as(f32, @floatFromInt(hover.start)) * cell.width, .y = top + cell.height - 1, .width = @as(f32, @floatFromInt(hover.end - hover.start)) * cell.width, .height = 1 }, fg);
            };
        }
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
                        var bytes: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(under.cp, &bytes) catch 0;
                        frame.labelFont(.{ .x = rect.x, .y = rect.y, .width = rect.width + cell.width, .height = rect.height }, bytes[0..n], self.colorsOf(under, false).bg, self.fontFor(under));
                    }
                },
                .underline => frame.rect(.{ .x = rect.x, .y = rect.y + rect.height - 2, .width = rect.width, .height = 2 }, t.cursor_color),
                .bar => frame.rect(.{ .x = rect.x, .y = rect.y, .width = 2, .height = rect.height }, t.cursor_color),
            }
        }
        // Where the scrollback is in view, a thumb on the right edge.
        if (offset > 0) {
            const total: f32 = @floatFromInt(s.historyCount() + s.rows);
            const height = @max(8, bounds.height * @as(f32, @floatFromInt(s.rows)) / total);
            const along = @as(f32, @floatFromInt(s.historyCount() - offset)) / @as(f32, @floatFromInt(s.historyCount()));
            frame.roundedRect(.{ .x = bounds.x + bounds.width - 5, .y = bounds.y + (bounds.height - height) * along, .width = 4, .height = height }, 2, ui.Color.rgb(blend(t.foreground, background)));
        }
        try frame.popClip();
        // Output moved the cursor: the input method's caret follows it.
        if (self.client != null and !self.queued and !std.meta.eql(self.caret, self.caret_sent)) {
            if (self.host.context.window) |window| {
                if (window.app.post(.{ .context = self, .call = run })) |_| {
                    self.queued = true;
                } else |err| self.fail(err);
            }
        }
        if (self.token) |token| try frame.textField(token, bounds, true);
        // Until the leaf is a registered text field nothing can take input
        // for it, so the box reads as read-only.
        try frame.semantic(.{ .id = id, .role = .text_box, .name = self.options.name, .value = self.cursorLine(), .bounds = bounds, .focused = focused, .read_only = self.token == null });
    }

    fn fontFor(self: *const TerminalView, cell: Cell) ui.Font {
        var value = self.font();
        if (cell.style.attrs.bold) value.weight = .bold;
        value.italic = cell.style.attrs.italic;
        return value;
    }

    /// Text in runs of one color and font. Wide characters go one by one at
    /// their cells, so a fallback font's advance cannot shift the grid.
    fn paintText(self: *TerminalView, frame: *ui.Frame, cells: []const Cell, abs: u64, range: ?term.selection.Range, ox: f32, top: f32, cw: f32, ch: f32) void {
        var glyphs: [1024]u8 = undefined;
        var x: usize = 0;
        while (x < cells.len) {
            // Stop emitting text when the frame runs low on commands, rather
            // than fail the whole frame.
            const buffer = &frame.context.command_buffer;
            if (buffer.storage.len - buffer.len < 64) return;
            const first = cells[x];
            if (first.wide == .spacer or first.cp == 0 or first.cp == ' ') {
                if (first.style.attrs.underline != .none or first.style.attrs.strike or first.style.attrs.overline) self.decorate(frame, first, selectedAt(range, abs, x), ox + @as(f32, @floatFromInt(x)) * cw, top, cw, ch);
                x += 1;
                continue;
            }
            const colors = self.colorsOf(first, selectedAt(range, abs, x));
            const face = self.fontFor(first);
            var len: usize = 0;
            var end = x;
            while (end < cells.len) {
                const c = cells[end];
                if (c.wide == .spacer) break;
                if (end > x and (c.wide == .wide or first.wide == .wide)) break;
                if (c.cp != 0 and c.cp != ' ') {
                    const other = self.colorsOf(c, selectedAt(range, abs, end));
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
                if (c.style.attrs.underline != .none or c.style.attrs.strike or c.style.attrs.overline) self.decorate(frame, c, selectedAt(range, abs, i), ox + @as(f32, @floatFromInt(i)) * cw, top, cw, ch);
            }
            x = end;
        }
    }

    fn decorate(self: *const TerminalView, frame: *ui.Frame, cell: Cell, selected: bool, left: f32, top: f32, cw: f32, ch: f32) void {
        const a = cell.style.attrs;
        const colors = self.colorsOf(cell, selected);
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
                if (input.typed(value.text)) self.typeBytes(value.text);
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
                if (input.typed(text.text)) self.typeBytes(text.text);
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
            .wheel => |wheel| return self.scrollWheel(wheel.position, wheel.delta.y),
            else => return false,
        }
    }

    fn key(self: *TerminalView, k: z.KeyInput) bool {
        const m = k.modifiers;
        const s = &self.terminal.screen;
        const only_shift = m.shift and !m.control and !m.alt and !m.super;
        // Copy and paste chords, and scrolling the view with Shift.
        if (m.control and m.shift and !m.alt and !m.super) switch (k.key) {
            .c => {
                _ = self.copy() catch |err| self.fail(err);
                return true;
            },
            .v => {
                self.paste() catch |err| self.fail(err);
                return true;
            },
            else => {},
        };
        if (only_shift) switch (k.key) {
            .insert => {
                self.paste() catch |err| self.fail(err);
                return true;
            },
            .page_up, .page_down => if (!s.onAlternate()) {
                const page: isize = @intCast(@max(s.rows, 2) - 1);
                _ = s.scrollView(if (k.key == .page_up) page else -page);
                return true;
            },
            .home, .end => if (!s.onAlternate()) {
                if (k.key == .end) _ = s.scrollViewToBottom() else _ = s.scrollView(@intCast(s.historyCount()));
                return true;
            },
            else => {},
        };
        if (m.control and !m.shift and !m.alt and k.key == .insert) {
            _ = self.copy() catch |err| self.fail(err);
            return true;
        }
        // Ctrl+C copies while there is a selection and interrupts otherwise.
        if (m.control and !m.shift and !m.alt and !m.super and k.key == .c and self.selection != null) {
            if (self.copy() catch false) {
                self.selection = null;
                return true;
            }
        }
        var buffer: [input.max_key]u8 = undefined;
        const bytes = input.key(k, s.modes, &buffer) orelse return false;
        self.typeBytes(bytes);
        return true;
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
        const px = @max(0, (point.x - self.bounds.x - self.options.padding) * self.scale);
        const py = @max(0, (point.y - self.bounds.y - self.options.padding) * self.scale);
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
        if (self.tracking(press.modifiers)) {
            const button = mouseButton(press.button);
            if (self.report(button, .press, press.position, press.modifiers)) self.reported_press = button;
            return true;
        }
        if (press.button != .primary) return false;
        const s = &self.terminal.screen;
        const at = self.cellAt(press.position);
        const position: Position = .{ .row = s.viewRow(at.row), .col = at.col };
        if (press.modifiers.control) if (self.linkAt(position)) |uri| {
            self.notify(.{ .open = uri });
            return true;
        };
        const now = std.time.milliTimestamp();
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

    fn pointerMove(self: *TerminalView, point: z.Point) bool {
        if (self.reported_press) |button| {
            return self.report(button, .motion, point, .{});
        }
        if (self.terminal.screen.modes.mouse == .any) {
            if (self.cellAt(point).inside) return self.report(.none, .motion, point, .{});
        }
        const selection = &(self.selection orelse return false);
        if (!selection.dragging) return false;
        const s = &self.terminal.screen;
        // Dragging past the top or bottom scrolls the view.
        const cell = self.cellSize();
        if (point.y < self.bounds.y + self.options.padding) {
            _ = s.scrollView(1);
        } else if (point.y > self.bounds.y + self.options.padding + @as(f32, @floatFromInt(s.rows)) * cell.height) _ = s.scrollView(-1);
        const at = self.cellAt(point);
        const head: Position = .{ .row = s.viewRow(at.row), .col = at.col };
        if (head.row == selection.head.row and head.col == selection.head.col) return false;
        selection.head = head;
        return true;
    }

    fn pointerUp(self: *TerminalView, press: z.PointerButtonInput) bool {
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
            _ = self.copy() catch |err| self.fail(err);
        }
        return true;
    }

    fn scrollWheel(self: *TerminalView, position: z.Point, delta: f32) bool {
        const s = &self.terminal.screen;
        self.wheel += delta / wheel_notch * @as(f32, @floatFromInt(self.options.scroll_lines));
        const lines: isize = @intFromFloat(@trunc(self.wheel));
        if (lines == 0) return true;
        self.wheel -= @floatFromInt(lines);
        const count: usize = @abs(lines);
        if (s.modes.mouse != .none) {
            for (0..count) |_| _ = self.report(if (lines < 0) .wheel_up else .wheel_down, .press, position, .{});
            return true;
        }
        if (s.onAlternate()) {
            if (!s.modes.alternate_scroll) return false;
            const arrow = if (lines < 0) (if (s.modes.cursor_keys) "\x1bOA" else "\x1b[A") else (if (s.modes.cursor_keys) "\x1bOB" else "\x1b[B");
            for (0..count) |_| self.send(arrow) catch |err| self.fail(err);
            return true;
        }
        _ = s.scrollView(-lines);
        return true;
    }

    /// The link at a position: one the program set, or an address in the
    /// text.
    fn linkAt(self: *TerminalView, at: Position) ?[]const u8 {
        const s = &self.terminal.screen;
        const line = s.rowAt(at.row) orelse return null;
        if (at.col >= line.cells.len) return null;
        if (s.link(line.cells[at.col].style.link)) |uri| return uri;
        var buffer: [2048]u8 = undefined;
        const found = term.links.at(line.cells, at.col, &buffer) orelse return null;
        self.hover = .{ .row = at.row, .start = found.start, .end = found.end };
        const n = @min(found.uri.len, self.hover.?.uri.len);
        @memcpy(self.hover.?.uri[0..n], found.uri[0..n]);
        self.hover.?.len = n;
        return self.hover.?.uri[0..n];
    }

    /// Hover over the leaf, outside the text field route: the link under
    /// the pointer is underlined.
    fn hoverInput(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *TerminalView = @ptrCast(@alignCast(ptr));
        const before = self.hover;
        switch (event) {
            .pointer_move => |local| {
                const point: z.Point = .{ .x = self.bounds.x + local.x, .y = self.bounds.y + local.y };
                const at = self.cellAt(point);
                self.hover = null;
                if (at.inside) {
                    const s = &self.terminal.screen;
                    const position: Position = .{ .row = s.viewRow(at.row), .col = at.col };
                    if (s.rowAt(position.row)) |line| if (at.col < line.cells.len) {
                        const id = line.cells[at.col].style.link;
                        if (id != 0 and s.link(id) != null) {
                            var start = at.col;
                            while (start > 0 and line.cells[start - 1].style.link == id) start -= 1;
                            var end = at.col + 1;
                            while (end < line.cells.len and line.cells[end].style.link == id) end += 1;
                            self.hover = .{ .row = position.row, .start = start, .end = @intCast(end) };
                        } else _ = self.linkAt(position);
                    };
                }
            },
            .pointer_leave => self.hover = null,
            // Presses, drags, the wheel and keys go through the text field
            // route.
            .pointer_down, .pointer_drag, .pointer_up, .pointer_cancel, .wheel, .key, .key_up => return false,
        }
        const was = before != null;
        const is = self.hover != null;
        return was != is or (was and is and (before.?.row != self.hover.?.row or before.?.start != self.hover.?.start));
    }
};

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

test "grid size follows the bounds and the cell size" {
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 4 } });
    defer terminal.deinit();
    var tv = TerminalView.init(undefined, std.testing.allocator, &terminal, .{ .cell_width = 8, .cell_height = 16, .padding = 4 });
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

fn testView(host: *view.Host, terminal: *term.Terminal, sent: *Sent, board: *Board) TerminalView {
    var tv = TerminalView.init(host, std.testing.allocator, terminal, .{ .cell_width = 10, .cell_height = 20, .padding = 0, .send = .{ .context = sent, .call = Sent.call }, .clipboard = .{ .context = board, .read = Board.read, .write = Board.write } });
    tv.bounds = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    return tv;
}

test "keys, text, pastes and replies reach the program" {
    const Empty = struct {
        fn build(_: *u8, _: *view.View) anyerror!void {}
    };
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 4 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    var tv = testView(&host, &terminal, &sent, &board);
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
    const Empty = struct {
        fn build(_: *u8, _: *view.View) anyerror!void {}
    };
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 4 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    var tv = testView(&host, &terminal, &sent, &board);
    tv.bind();
    tv.feed("hello you\r\nsecond");
    // Drag from 'e' to 'y' of the first line.
    try std.testing.expect(tv.handle(.{ .pointer_down = .{ .position = .{ .x = 15, .y = 5 } } }));
    try std.testing.expect(tv.handle(.{ .pointer_move = .{ .x = 65, .y = 5 } }));
    try std.testing.expect(tv.handle(.{ .pointer_up = .{ .position = .{ .x = 65, .y = 5 } } }));
    try std.testing.expect(try tv.copy());
    try std.testing.expectEqualStrings("ello y", board.text[0..board.len]);
    // Ctrl+C with a selection copies instead of interrupting.
    board.len = 0;
    try std.testing.expect(tv.handle(.{ .key_input = .{ .key = .c, .modifiers = .{ .control = true } } }));
    try std.testing.expectEqualStrings("ello y", board.text[0..board.len]);
    try std.testing.expect(tv.selection == null);
    try std.testing.expectEqual(@as(usize, 0), sent.len);
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
    const Empty = struct {
        fn build(_: *u8, _: *view.View) anyerror!void {}
    };
    var state: u8 = 0;
    var storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, storage.buffers(), .{});
    var terminal = try term.Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 2 } });
    defer terminal.deinit();
    var sent: Sent = .{};
    var board: Board = .{};
    var tv = testView(&host, &terminal, &sent, &board);
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
    try std.testing.expect(tv.handle(.{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .x = 0, .y = 32 } } }));
    try std.testing.expectEqualStrings("\x1b[B\x1b[B", sent.text());
}

test {
    std.testing.refAllDecls(TerminalView);
}
