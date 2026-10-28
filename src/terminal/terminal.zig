//! A terminal emulator's model: bytes from the program go in through
//! `feed`, the screen changes, and answers the program asked for (cursor
//! position, device attributes, colors) collect in `replies` for the
//! caller to send back. Titles, the bell, the working directory and
//! clipboard requests reach the host through `Handler`.
const std = @import("std");
const parser_module = @import("parser.zig");
const screen_module = @import("screen.zig");
const graphics = @import("graphics.zig");
const theme_module = @import("theme.zig");

const Parser = parser_module.Parser;
const Action = parser_module.Action;
const Csi = parser_module.Csi;
pub const Screen = screen_module.Screen;
pub const Color = screen_module.Color;
pub const Style = screen_module.Style;

/// What programs may do with the clipboard through OSC 52. Both are off
/// by default: a program could otherwise read what the user copied
/// elsewhere, or replace it unseen.
pub const ClipboardPolicy = struct {
    read: bool = false,
    write: bool = false,
    /// Programs' reads go on through a `Mirror`'s frames, for the
    /// terminal showing them to answer, rather than to the handler.
    forward_read: bool = false,
};

pub const Event = union(enum) {
    bell,
    /// The window title changed; borrowed until the next feed.
    title: []const u8,
    /// The program's working directory, as the `file://` URI it reported.
    directory: []const u8,
    /// Text a program wants on the clipboard, decoded; allowed by policy.
    clipboard_write: []const u8,
    /// A program asks for the clipboard; allowed by policy. Answer with
    /// `Terminal.answerClipboard`.
    clipboard_read,
    /// A desktop notification a program asks for (OSC 9, OSC 777); the
    /// text is borrowed until the next feed.
    notify: struct { title: []const u8, body: []const u8 },
};

pub const Handler = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, Event) void,
};

pub const Options = struct {
    screen: screen_module.Options = .{},
    /// Longest OSC payload kept; longer ones are dropped whole.
    osc_bytes: usize = 4096,
    clipboard: ClipboardPolicy = .{},
    handler: ?Handler = null,
    /// Default colors, also the answers to color queries.
    foreground: u24 = 0xd4d4d4,
    background: u24 = 0x1e1e1e,
    cursor: u24 = 0xd4d4d4,
    /// The most bytes the images programs show take (the Kitty graphics
    /// protocol), on each screen; 0 refuses images, for programs to show
    /// something else.
    image_limit: usize = graphics.default_limit,
};

pub const max_title = 256;
pub const reply_bytes = 4096;

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    screen: Screen,
    parser: Parser,
    osc_storage: []u8,
    /// Decoded OSC 52 text: the last a program wrote, which mirrors pass on
    /// whatever the policy.
    clipboard_storage: []u8,
    clipboard_len: usize = 0,
    /// Writes to the clipboard so far, and reads forwarded to mirrors with
    /// their selections ('c' or 'p'), for the next mirror to frame.
    clipboard_writes: u64 = 0,
    forwarded_reads: [8]u8 = undefined,
    forwarded_len: usize = 0,
    options: Options,
    replies: [reply_bytes]u8 = undefined,
    reply_len: usize = 0,
    title_bytes: [max_title]u8 = undefined,
    title_len: usize = 0,
    palette: [256]u24 = default_palette,
    foreground: u24,
    background: u24,
    cursor_color: u24,
    /// The colors programs return to when they reset them: the theme's.
    /// Colors a program set stay until it resets them, even as the theme
    /// changes.
    base_palette: [256]u24 = default_palette,
    base_foreground: u24,
    base_background: u24,
    base_cursor: u24,
    palette_set: std.StaticBitSet(256) = .initEmpty(),
    foreground_set: bool = false,
    background_set: bool = false,
    cursor_set: bool = false,
    /// Cell size in device pixels, for size reports; set by the view.
    cell_width: u16 = 0,
    cell_height: u16 = 0,
    bells: u64 = 0,
    /// The pointer's shape a program asked for with OSC 22 (`pointer`,
    /// `crosshair`, `col-resize`…), until it takes or leaves the mouse.
    pointer_shape_bytes: [32]u8 = undefined,
    pointer_shape_len: usize = 0,
    /// Images of the primary screen and of the alternate one.
    images: [2]graphics.Storage,
    receiver: graphics.Receiver = .{},

    pub fn init(allocator: std.mem.Allocator, options: Options) !Terminal {
        var screen = try Screen.init(allocator, options.screen);
        errdefer screen.deinit();
        const osc = try allocator.alloc(u8, options.osc_bytes);
        errdefer allocator.free(osc);
        const clipboard = try allocator.alloc(u8, options.osc_bytes);
        return .{ .allocator = allocator, .screen = screen, .parser = Parser.init(osc), .osc_storage = osc, .clipboard_storage = clipboard, .options = options, .foreground = options.foreground, .background = options.background, .cursor_color = options.cursor, .base_foreground = options.foreground, .base_background = options.background, .base_cursor = options.cursor, .images = .{ .init(allocator, options.image_limit, 0), .init(allocator, options.image_limit, 1 << 62) } };
    }

    pub fn deinit(self: *Terminal) void {
        self.screen.deinit();
        self.allocator.free(self.osc_storage);
        self.allocator.free(self.clipboard_storage);
        for (&self.images) |*storage| storage.deinit();
        self.receiver.deinit(self.allocator);
    }

    /// The images and placements of the screen that shows.
    pub fn activeImages(self: *Terminal) *graphics.Storage {
        return &self.images[@intFromBool(self.screen.onAlternate())];
    }
    /// The row placements count at the top of the view, as the screen
    /// shows it scrolled back.
    pub fn imagesTop(self: *const Terminal) u64 {
        return graphics.Storage.top(&self.screen) - self.screen.viewportOffset();
    }

    /// Interpret output from the program.
    pub fn feed(self: *Terminal, bytes: []const u8) void {
        self.parser.feed(bytes, self);
    }

    /// Answers waiting to go back to the program.
    pub fn pendingReplies(self: *const Terminal) []const u8 {
        return self.replies[0..self.reply_len];
    }
    pub fn clearReplies(self: *Terminal) void {
        self.reply_len = 0;
    }
    pub fn title(self: *const Terminal) []const u8 {
        return self.title_bytes[0..self.title_len];
    }
    /// The pointer shape a program asked for with OSC 22, or empty.
    pub fn pointerShape(self: *const Terminal) []const u8 {
        return self.pointer_shape_bytes[0..self.pointer_shape_len];
    }

    /// Make these the default colors, as a theme sets them. Colors a
    /// program set keep its values until it resets them.
    pub fn setColors(self: *Terminal, foreground: u24, background: u24, cursor: u24, palette: [256]u24) void {
        self.base_foreground = foreground;
        self.base_background = background;
        self.base_cursor = cursor;
        self.base_palette = palette;
        if (!self.foreground_set) self.foreground = foreground;
        if (!self.background_set) self.background = background;
        if (!self.cursor_set) self.cursor_color = cursor;
        for (&self.palette, palette, 0..) |*color, base, i| {
            if (!self.palette_set.isSet(i)) color.* = base;
        }
        self.screen.revision +%= 1;
    }

    fn resetColors(self: *Terminal) void {
        self.palette = self.base_palette;
        self.foreground = self.base_foreground;
        self.background = self.base_background;
        self.cursor_color = self.base_cursor;
        self.palette_set = .initEmpty();
        self.foreground_set = false;
        self.background_set = false;
        self.cursor_set = false;
    }

    /// Take a size and the cell's size in pixels, as a terminal no view
    /// shows learns them from the window that shows it.
    pub fn resizePixels(self: *Terminal, cols: u16, rows: u16, cell_width: u16, cell_height: u16) !void {
        try self.resize(cols, rows, &.{});
        self.cell_width = cell_width;
        self.cell_height = cell_height;
    }

    /// Change the screen's size, as `Screen.resizeTracking` does: a new
    /// width rewraps the primary screen and its scrollback, and `tracked`
    /// positions there move with their cells, as the images placed there
    /// do.
    pub fn resize(self: *Terminal, cols: u16, rows: u16, tracked: []screen_module.Position) !void {
        const placements = self.images[0].placements.items;
        const positions = try self.allocator.alloc(screen_module.Position, tracked.len + placements.len);
        defer self.allocator.free(positions);
        @memcpy(positions[0..tracked.len], tracked);
        for (placements, positions[tracked.len..]) |p, *at| at.* = .{ .row = p.row, .col = p.col };
        try self.screen.resizeTracking(cols, rows, positions);
        @memcpy(tracked, positions[0..tracked.len]);
        for (placements, positions[tracked.len..]) |*p, at| if (!p.virtual) {
            p.row = at.row;
            p.col = at.col;
        };
    }

    /// Take a theme's colors as the defaults, as `setColors` does.
    pub fn useTheme(self: *Terminal, theme: theme_module.Theme) void {
        self.setColors(theme.foreground, theme.background, theme.cursorColor(), theme.palette256());
    }

    /// Clear the scrollback and the screen above the cursor's line, which
    /// moves to the top, as a user's clear does; nothing on a full-screen
    /// program's screen. True when it cleared.
    pub fn clearScreen(self: *Terminal) bool {
        return self.screen.clearToCursor();
    }

    /// Resolve a cell color to RGB.
    pub fn rgb(self: *const Terminal, color: Color, foreground: bool) u24 {
        return switch (color.kind) {
            .default => if (foreground) self.foreground else self.background,
            .palette => self.palette[@as(u8, @truncate(color.value))],
            .rgb => color.value,
        };
    }

    /// Answer a clipboard read the policy allowed, with `text` from the
    /// clipboard.
    pub fn answerClipboard(self: *Terminal, text: []const u8) void {
        const encoder = std.base64.standard.Encoder;
        const size = encoder.calcSize(text.len);
        if (self.reply_len + size + 10 > reply_bytes) return;
        self.reply("\x1b]52;c;");
        _ = encoder.encode(self.replies[self.reply_len..][0..size], text);
        self.reply_len += size;
        self.reply("\x1b\\");
    }

    fn reply(self: *Terminal, bytes: []const u8) void {
        if (self.reply_len + bytes.len > reply_bytes) return;
        @memcpy(self.replies[self.reply_len..][0..bytes.len], bytes);
        self.reply_len += bytes.len;
    }
    fn replyPrint(self: *Terminal, comptime format: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.replies[self.reply_len..], format, args) catch return;
        self.reply_len += written.len;
    }
    fn emit(self: *Terminal, event: Event) void {
        const handler = self.options.handler orelse return;
        handler.call(handler.context, event);
    }

    /// Called by the parser for each action.
    pub fn action(self: *Terminal, value: Action) void {
        switch (value) {
            .print => |cp| self.screen.print(cp),
            .execute => |byte| self.execute(byte),
            .csi => |c| self.handleCsi(c),
            .esc => |e| self.handleEsc(e.intermediates, e.final),
            .osc => |payload| self.handleOsc(payload),
            .apc_start => self.receiver.start(self.allocator),
            .apc_data => |bytes| self.receiver.data(self.allocator, bytes),
            .apc_end => |ok| {
                const command = self.receiver.end() orelse return;
                if (!ok) return;
                const grid: graphics.Grid = .{ .screen = &self.screen, .cell_width = self.cell_width, .cell_height = self.cell_height };
                // Placing moves the cursor, deleting changes what shows.
                self.screen.revision +%= 1;
                const response = self.activeImages().execute(command.control, command.payload, grid) orelse return;
                var buffer: [256]u8 = undefined;
                self.reply(response.write(&buffer) catch return);
            },
        }
    }

    fn execute(self: *Terminal, byte: u8) void {
        const s = &self.screen;
        switch (byte) {
            0x07 => {
                self.bells += 1;
                self.emit(.bell);
            },
            0x08 => s.backspace(),
            0x09 => s.tabForward(1),
            0x0a, 0x0b, 0x0c => s.lineFeed(),
            0x0d => s.carriageReturn(),
            0x0e => s.shiftTo(1),
            0x0f => s.shiftTo(0),
            else => {},
        }
    }

    fn handleEsc(self: *Terminal, intermediates: []const u8, final: u8) void {
        const s = &self.screen;
        if (intermediates.len == 0) switch (final) {
            '7' => s.saveCursor(),
            '8' => s.restoreCursor(),
            'D' => s.index(),
            'E' => s.nextLine(),
            'H' => s.setTab(),
            'M' => s.reverseIndex(),
            'c' => {
                s.reset();
                self.resetColors();
                self.title_len = 0;
                for (&self.images) |*storage| storage.clear();
            },
            '=' => s.modes.keypad = true,
            '>' => s.modes.keypad = false,
            'Z' => self.reply(primary_attributes),
            else => {},
        } else if (intermediates.len == 1) switch (intermediates[0]) {
            '(', ')' => s.designate(if (intermediates[0] == '(') 0 else 1, switch (final) {
                '0' => .dec_graphics,
                'A' => .uk,
                else => .ascii,
            }),
            '#' => if (final == '8') s.alignmentTest(),
            else => {},
        };
    }

    fn handleCsi(self: *Terminal, c: Csi) void {
        const s = &self.screen;
        const p = &c.params;
        if (c.intermediates.len > 0) return self.csiIntermediate(c);
        switch (c.private) {
            0 => {},
            '?' => return switch (c.final) {
                'h', 'l' => for (p.slice()) |mode| self.setPrivateMode(mode, c.final == 'h'),
                'n' => if (p.get(0, 0) == 6) self.replyPrint("\x1b[?{d};{d}R", .{ self.reportRow(), s.cursor.x + 1 }),
                else => {},
            },
            '>' => return switch (c.final) {
                'c' => self.reply("\x1b[>1;10;0c"),
                'q' => self.reply("\x1bP>|ziggurat\x1b\\"),
                else => {},
            },
            else => return,
        }
        switch (c.final) {
            '@' => s.insertChars(p.get(0, 1)),
            'A' => s.up(p.get(0, 1)),
            'B', 'e' => s.down(p.get(0, 1)),
            'C', 'a' => s.forward(p.get(0, 1)),
            'D' => s.backward(p.get(0, 1)),
            'E' => {
                s.down(p.get(0, 1));
                s.carriageReturn();
            },
            'F' => {
                s.up(p.get(0, 1));
                s.carriageReturn();
            },
            'G', '`' => s.moveToColumn(p.get(0, 1) - 1),
            'H', 'f' => s.moveTo(p.get(1, 1) - 1, p.get(0, 1) - 1),
            'I' => s.tabForward(p.get(0, 1)),
            'J' => {
                const mode = erase(p.get(0, 0)) orelse return;
                s.eraseDisplay(mode);
                // Clearing the screen clears its images too.
                if (mode == .all) self.activeImages().clear();
            },
            'K' => s.eraseLine(erase(p.get(0, 0)) orelse return),
            'L' => s.insertLines(p.get(0, 1)),
            'M' => s.deleteLines(p.get(0, 1)),
            'P' => s.deleteChars(p.get(0, 1)),
            'S' => s.scrollUp(p.get(0, 1)),
            'T' => if (p.len <= 1) s.scrollDown(p.get(0, 1)),
            'X' => s.eraseChars(p.get(0, 1)),
            'Z' => s.tabBackward(p.get(0, 1)),
            'b' => s.repeat(p.get(0, 1)),
            'c' => if (p.get(0, 0) == 0) self.reply(primary_attributes),
            'd' => s.moveToRow(p.get(0, 1) - 1),
            'g' => switch (p.get(0, 0)) {
                0 => s.clearTab(false),
                3 => s.clearTab(true),
                else => {},
            },
            'h', 'l' => for (p.slice()) |mode| switch (mode) {
                4 => s.modes.insert = c.final == 'h',
                20 => s.modes.newline = c.final == 'h',
                else => {},
            },
            'm' => self.sgr(p),
            'n' => switch (p.get(0, 0)) {
                5 => self.reply("\x1b[0n"),
                6 => self.replyPrint("\x1b[{d};{d}R", .{ self.reportRow(), s.cursor.x + 1 }),
                else => {},
            },
            'r' => s.setRegion(p.get(0, 1) - 1, p.get(1, s.rows) - 1),
            's' => s.saveCursor(),
            'u' => s.restoreCursor(),
            't' => switch (p.get(0, 0)) {
                14 => self.replyPrint("\x1b[4;{d};{d}t", .{ @as(u32, s.rows) * self.cell_height, @as(u32, s.cols) * self.cell_width }),
                16 => self.replyPrint("\x1b[6;{d};{d}t", .{ self.cell_height, self.cell_width }),
                18 => self.replyPrint("\x1b[8;{d};{d}t", .{ s.rows, s.cols }),
                else => {},
            },
            else => {},
        }
    }

    fn csiIntermediate(self: *Terminal, c: Csi) void {
        const s = &self.screen;
        const p = &c.params;
        if (c.intermediates.len != 1) return;
        switch (c.intermediates[0]) {
            ' ' => if (c.final == 'q' and c.private == 0) {
                const shape = p.get(0, 1);
                s.modes.cursor_blink = shape == 0 or shape % 2 == 1;
                s.modes.cursor_shape = switch (shape) {
                    3, 4 => .underline,
                    5, 6 => .bar,
                    else => .block,
                };
                s.revision +%= 1;
            },
            '!' => if (c.final == 'p') s.softReset(),
            '$' => if (c.final == 'p') {
                const mode = p.get(0, 0);
                const state: u8 = if (c.private == '?') self.privateModeState(mode) else switch (mode) {
                    4 => if (s.modes.insert) 1 else 2,
                    20 => if (s.modes.newline) 1 else 2,
                    else => 0,
                };
                if (c.private == '?') self.replyPrint("\x1b[?{d};{d}$y", .{ mode, state }) else self.replyPrint("\x1b[{d};{d}$y", .{ mode, state });
            },
            else => {},
        }
    }

    fn reportRow(self: *const Terminal) u32 {
        const s = &self.screen;
        const top: u16 = if (s.modes.origin) s.top else 0;
        return @as(u32, s.cursor.y - top) + 1;
    }

    /// Taking or leaving the mouse drops the pointer shape asked for.
    fn setMouse(self: *Terminal, tracking: screen_module.MouseTracking) void {
        if ((tracking == .none) != (self.screen.modes.mouse == .none)) self.pointer_shape_len = 0;
        self.screen.modes.mouse = tracking;
    }

    fn setPrivateMode(self: *Terminal, mode: u16, on: bool) void {
        const s = &self.screen;
        const m = &s.modes;
        switch (mode) {
            1 => m.cursor_keys = on,
            5 => m.reverse_video = on,
            6 => {
                m.origin = on;
                s.moveTo(0, 0);
            },
            7 => m.autowrap = on,
            9 => self.setMouse(if (on) .x10 else .none),
            12 => m.cursor_blink = on,
            25 => m.cursor_visible = on,
            47 => s.useAlternate(on, false, false),
            66 => m.keypad = on,
            1000 => self.setMouse(if (on) .normal else .none),
            1002 => self.setMouse(if (on) .button else .none),
            1003 => self.setMouse(if (on) .any else .none),
            1004 => m.focus_events = on,
            1005 => m.mouse_encoding = if (on) .utf8 else .x10,
            1006 => m.mouse_encoding = if (on) .sgr else .x10,
            1007 => m.alternate_scroll = on,
            1015 => m.mouse_encoding = if (on) .urxvt else .x10,
            1016 => m.mouse_encoding = if (on) .sgr_pixels else .x10,
            1047 => {
                s.useAlternate(on, false, !on);
                if (!on) self.images[1].clear();
            },
            1048 => if (on) s.saveCursor() else s.restoreCursor(),
            1049 => {
                s.useAlternate(on, true, true);
                self.images[1].clear();
            },
            2004 => m.bracketed_paste = on,
            2026 => m.synchronized = on,
            else => {},
        }
        s.revision +%= 1;
    }

    /// A private mode's state as DECRQM reports it: 1 set, 2 reset, 0 for
    /// one it does not know.
    pub fn privateModeState(self: *const Terminal, mode: u16) u8 {
        const m = &self.screen.modes;
        const value: ?bool = switch (mode) {
            1 => m.cursor_keys,
            5 => m.reverse_video,
            6 => m.origin,
            7 => m.autowrap,
            9 => m.mouse == .x10,
            12 => m.cursor_blink,
            25 => m.cursor_visible,
            47, 1047, 1049 => self.screen.on_alternate,
            66 => m.keypad,
            1000 => m.mouse == .normal,
            1002 => m.mouse == .button,
            1003 => m.mouse == .any,
            1004 => m.focus_events,
            1005 => m.mouse_encoding == .utf8,
            1006 => m.mouse_encoding == .sgr,
            1007 => m.alternate_scroll,
            1015 => m.mouse_encoding == .urxvt,
            1016 => m.mouse_encoding == .sgr_pixels,
            2004 => m.bracketed_paste,
            2026 => m.synchronized,
            else => null,
        };
        const set = value orelse return 0;
        return if (set) 1 else 2;
    }

    fn sgr(self: *Terminal, p: *const parser_module.Params) void {
        const style = &self.screen.cursor.style;
        if (p.len == 0) {
            const link = style.link;
            style.* = .{ .link = link };
            return;
        }
        var i: usize = 0;
        while (i < p.len) : (i += 1) {
            const code = p.values[i];
            // Subparameters belong to the code before them.
            var subs: usize = 0;
            while (i + subs + 1 < p.len and p.colon[i + subs + 1]) subs += 1;
            const a = &style.attrs;
            switch (code) {
                0 => {
                    const link = style.link;
                    style.* = .{ .link = link };
                },
                1 => a.bold = true,
                2 => a.dim = true,
                3 => a.italic = true,
                4 => a.underline = if (subs > 0) switch (p.values[i + 1]) {
                    0 => .none,
                    2 => .double,
                    3 => .curly,
                    4 => .dotted,
                    5 => .dashed,
                    else => .single,
                } else .single,
                5, 6 => a.blink = true,
                7 => a.inverse = true,
                8 => a.hidden = true,
                9 => a.strike = true,
                21 => a.underline = .double,
                22 => {
                    a.bold = false;
                    a.dim = false;
                },
                23 => a.italic = false,
                24 => a.underline = .none,
                25 => a.blink = false,
                27 => a.inverse = false,
                28 => a.hidden = false,
                29 => a.strike = false,
                30...37 => style.fg = Color.palette(@intCast(code - 30)),
                39 => style.fg = .{},
                40...47 => style.bg = Color.palette(@intCast(code - 40)),
                49 => style.bg = .{},
                53 => a.overline = true,
                55 => a.overline = false,
                59 => style.underline_color = .{},
                90...97 => style.fg = Color.palette(@intCast(code - 90 + 8)),
                100...107 => style.bg = Color.palette(@intCast(code - 100 + 8)),
                38, 48, 58 => {
                    const parsed = extendedColor(p, i, subs);
                    if (parsed.color) |color| switch (code) {
                        38 => style.fg = color,
                        48 => style.bg = color,
                        else => style.underline_color = color,
                    };
                    i += parsed.consumed;
                    continue;
                },
                else => {},
            }
            i += subs;
        }
    }

    fn handleOsc(self: *Terminal, payload: []const u8) void {
        const split = std.mem.indexOfScalar(u8, payload, ';');
        const code_text = payload[0 .. split orelse payload.len];
        const rest = if (split) |at| payload[at + 1 ..] else "";
        const code = std.fmt.parseInt(u16, code_text, 10) catch return;
        switch (code) {
            0, 2 => {
                var len = @min(rest.len, max_title);
                // Keep whole UTF-8 sequences.
                while (len > 0 and len < rest.len and rest[len] & 0xc0 == 0x80) len -= 1;
                @memcpy(self.title_bytes[0..len], rest[0..len]);
                self.title_len = len;
                self.emit(.{ .title = self.title() });
            },
            4 => {
                var parts = std.mem.splitScalar(u8, rest, ';');
                while (parts.next()) |index_text| {
                    const spec = parts.next() orelse break;
                    const index = std.fmt.parseInt(u8, index_text, 10) catch continue;
                    if (std.mem.eql(u8, spec, "?")) {
                        self.replyColor("4;{d};", index, self.palette[index]);
                    } else if (parseColor(spec)) |value| {
                        self.palette[index] = value;
                        self.palette_set.set(index);
                        self.screen.revision +%= 1;
                    }
                }
            },
            104 => {
                if (rest.len == 0) {
                    self.palette = self.base_palette;
                    self.palette_set = .initEmpty();
                } else {
                    var parts = std.mem.splitScalar(u8, rest, ';');
                    while (parts.next()) |index_text| {
                        const index = std.fmt.parseInt(u8, index_text, 10) catch continue;
                        self.palette[index] = self.base_palette[index];
                        self.palette_set.unset(index);
                    }
                }
                self.screen.revision +%= 1;
            },
            7 => self.emit(.{ .directory = rest }),
            9 => {
                // ConEmu's progress (9;4) and the like are not notifications.
                if (rest.len > 1 and std.ascii.isDigit(rest[0]) and rest[1] == ';') return;
                self.emit(.{ .notify = .{ .title = "", .body = rest } });
            },
            777 => {
                var parts = std.mem.splitScalar(u8, rest, ';');
                if (!std.mem.eql(u8, parts.next() orelse "", "notify")) return;
                const heading = parts.next() orelse "";
                self.emit(.{ .notify = .{ .title = heading, .body = parts.rest() } });
            },
            22 => {
                const len = @min(rest.len, self.pointer_shape_bytes.len);
                @memcpy(self.pointer_shape_bytes[0..len], rest[0..len]);
                self.pointer_shape_len = len;
                self.screen.revision +%= 1;
            },
            8 => {
                // Parameters, then the URI, which may itself hold ';'.
                const at = std.mem.indexOfScalar(u8, rest, ';') orelse return;
                self.screen.setLink(rest[at + 1 ..]);
            },
            10, 11, 12 => {
                const target = switch (code) {
                    10 => &self.foreground,
                    11 => &self.background,
                    else => &self.cursor_color,
                };
                if (std.mem.eql(u8, rest, "?")) {
                    self.replyColor("{d};", code, target.*);
                } else if (parseColor(rest)) |value| {
                    target.* = value;
                    switch (code) {
                        10 => self.foreground_set = true,
                        11 => self.background_set = true,
                        else => self.cursor_set = true,
                    }
                    self.screen.revision +%= 1;
                }
            },
            110, 111, 112 => {
                switch (code) {
                    110 => {
                        self.foreground = self.base_foreground;
                        self.foreground_set = false;
                    },
                    111 => {
                        self.background = self.base_background;
                        self.background_set = false;
                    },
                    else => {
                        self.cursor_color = self.base_cursor;
                        self.cursor_set = false;
                    },
                }
                self.screen.revision +%= 1;
            },
            52 => {
                const at = std.mem.indexOfScalar(u8, rest, ';') orelse return;
                const data = rest[at + 1 ..];
                if (std.mem.eql(u8, data, "?")) {
                    if (self.options.clipboard.forward_read) {
                        if (self.forwarded_len < self.forwarded_reads.len) {
                            self.forwarded_reads[self.forwarded_len] = if (std.mem.indexOfScalar(u8, rest[0..at], 'p') != null) 'p' else 'c';
                            self.forwarded_len += 1;
                        }
                    } else if (self.options.clipboard.read) self.emit(.clipboard_read);
                    return;
                }
                const decoder = std.base64.standard.Decoder;
                const size = decoder.calcSizeForSlice(data) catch return;
                if (size > self.clipboard_storage.len) return;
                decoder.decode(self.clipboard_storage[0..size], data) catch return;
                self.clipboard_len = size;
                self.clipboard_writes += 1;
                if (!self.options.clipboard.write) return;
                self.emit(.{ .clipboard_write = self.clipboard_storage[0..size] });
            },
            else => {},
        }
    }

    fn replyColor(self: *Terminal, comptime prefix: []const u8, number: anytype, value: u24) void {
        const r: u16 = @as(u8, @truncate(value >> 16));
        const g: u16 = @as(u8, @truncate(value >> 8));
        const b: u16 = @as(u8, @truncate(value));
        self.replyPrint("\x1b]" ++ prefix ++ "rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ number, r * 257, g * 257, b * 257 });
    }
};

const primary_attributes = "\x1b[?62;22c";

fn erase(mode: u16) ?Screen.Erase {
    return switch (mode) {
        0 => .below,
        1 => .above,
        2 => .all,
        3 => .scrollback,
        else => null,
    };
}

/// `38;5;n`, `38;2;r;g;b`, `38:5:n`, `38:2::r:g:b` and `38:2:r:g:b`; the
/// parameters taken after the code.
fn extendedColor(p: *const parser_module.Params, i: usize, subs: usize) struct { color: ?Color, consumed: usize } {
    const v = p.values;
    if (subs > 0) {
        const kind = v[i + 1];
        if (kind == 5 and subs >= 2) return .{ .color = Color.palette(@truncate(v[i + 2])), .consumed = subs };
        if (kind == 2 and subs >= 4) {
            // With a color space id the components start one later.
            const first = if (subs >= 5) i + 3 else i + 2;
            return .{ .color = Color.rgb(pack(v[first], v[first + 1], v[first + 2])), .consumed = subs };
        }
        return .{ .color = null, .consumed = subs };
    }
    if (i + 1 >= p.len) return .{ .color = null, .consumed = 0 };
    switch (v[i + 1]) {
        5 => if (i + 2 < p.len) return .{ .color = Color.palette(@truncate(v[i + 2])), .consumed = 2 },
        2 => if (i + 4 < p.len) return .{ .color = Color.rgb(pack(v[i + 2], v[i + 3], v[i + 4])), .consumed = 4 },
        else => {},
    }
    return .{ .color = null, .consumed = p.len - i - 1 };
}

fn pack(r: u16, g: u16, b: u16) u24 {
    return @as(u24, @min(r, 255)) << 16 | @as(u24, @min(g, 255)) << 8 | @min(b, 255);
}

/// `rgb:r/g/b` with one to four hex digits per component, or `#rrggbb`.
pub fn parseColor(spec: []const u8) ?u24 {
    if (spec.len == 7 and spec[0] == '#') return std.fmt.parseInt(u24, spec[1..], 16) catch null;
    if (!std.mem.startsWith(u8, spec, "rgb:")) return null;
    var parts = std.mem.splitScalar(u8, spec[4..], '/');
    var value: u24 = 0;
    for (0..3) |_| {
        const part = parts.next() orelse return null;
        if (part.len == 0 or part.len > 4) return null;
        const raw = std.fmt.parseInt(u16, part, 16) catch return null;
        const max = (@as(u32, 1) << @intCast(part.len * 4)) - 1;
        const scaled: u24 = @intCast((@as(u32, raw) * 255 + max / 2) / max);
        value = value << 8 | scaled;
    }
    if (parts.next() != null) return null;
    return value;
}

pub const default_palette: [256]u24 = blk: {
    var colors: [256]u24 = undefined;
    const base = [16]u24{ 0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5, 0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff };
    for (base, 0..) |c, i| colors[i] = c;
    const steps = [6]u24{ 0, 95, 135, 175, 215, 255 };
    for (0..216) |i| colors[16 + i] = steps[i / 36] << 16 | steps[(i / 6) % 6] << 8 | steps[i % 6];
    for (0..24) |i| {
        const level: u24 = 8 + 10 * @as(u24, @intCast(i));
        colors[232 + i] = level << 16 | level << 8 | level;
    }
    break :blk colors;
};

fn rowText(t: *const Terminal, y: usize, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (t.screen.row(y)) |cell| {
        if (cell.wide == .spacer) continue;
        len += std.unicode.utf8Encode(if (cell.cp == 0) ' ' else cell.cp, buffer[len..]) catch unreachable;
    }
    while (len > 0 and buffer[len - 1] == ' ') len -= 1;
    return buffer[0..len];
}

const Recorder = struct {
    titles: usize = 0,
    bells: usize = 0,
    written: [64]u8 = undefined,
    written_len: usize = 0,
    reads: usize = 0,
    fn call(context: ?*anyopaque, event: Event) void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        switch (event) {
            .title => self.titles += 1,
            .bell => self.bells += 1,
            .clipboard_write => |bytes| {
                @memcpy(self.written[0..bytes.len], bytes);
                self.written_len = bytes.len;
            },
            .clipboard_read => self.reads += 1,
            .directory, .notify => {},
        }
    }
};

test "cursor movement, erasing and colors from control sequences" {
    var t = try Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 4 } });
    defer t.deinit();
    var buffer: [64]u8 = undefined;
    t.feed("hello\r\nworld\x1b[1;3H\x1b[1;31mX\x1b[0m\x1b[2;2H\x1b[K");
    try std.testing.expectEqualStrings("heXlo", rowText(&t, 0, &buffer));
    try std.testing.expectEqualStrings("w", rowText(&t, 1, &buffer));
    const x = t.screen.row(0)[2];
    try std.testing.expect(x.style.attrs.bold);
    try std.testing.expectEqual(Color.palette(1), x.style.fg);
    t.feed("\x1b[38;2;1;2;3;48;5;200mA\x1b[38:2::4:5:6mB\x1b[4:3;58;5;9mC");
    const a = t.screen.row(1)[1];
    try std.testing.expectEqual(Color.rgb(0x010203), a.style.fg);
    try std.testing.expectEqual(Color.palette(200), a.style.bg);
    const b = t.screen.row(1)[2];
    try std.testing.expectEqual(Color.rgb(0x040506), b.style.fg);
    try std.testing.expectEqual(Color.palette(200), b.style.bg);
    const c = t.screen.row(1)[3];
    try std.testing.expectEqual(screen_module.Underline.curly, c.style.attrs.underline);
    try std.testing.expectEqual(Color.palette(9), c.style.underline_color);
    t.feed("\x1b[2J\x1b[H");
    try std.testing.expectEqualStrings("", rowText(&t, 1, &buffer));
    try std.testing.expectEqual(@as(u16, 0), t.screen.cursor.y);
}

test "reports, modes and the alternate screen" {
    var t = try Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 4 } });
    defer t.deinit();
    var buffer: [64]u8 = undefined;
    t.feed("ab\x1b[6n\x1b[c\x1b[?2004h\x1b[?2004$p\x1b[18t");
    try std.testing.expectEqualStrings("\x1b[1;3R\x1b[?62;22c\x1b[?2004;1$y\x1b[8;4;10t", t.pendingReplies());
    try std.testing.expect(t.screen.modes.bracketed_paste);
    t.clearReplies();
    t.feed("\x1b[?1049h\x1b[2;1Hfull screen\x1b[?1000h\x1b[?1006h");
    try std.testing.expect(t.screen.onAlternate());
    try std.testing.expectEqual(screen_module.MouseTracking.normal, t.screen.modes.mouse);
    try std.testing.expectEqual(screen_module.MouseEncoding.sgr, t.screen.modes.mouse_encoding);
    t.feed("\x1b[?1049l");
    try std.testing.expectEqualStrings("ab", rowText(&t, 0, &buffer));
    try std.testing.expectEqual(@as(u16, 2), t.screen.cursor.x);
    t.feed("\x1b[5 q");
    try std.testing.expectEqual(screen_module.CursorShape.bar, t.screen.modes.cursor_shape);
    try std.testing.expect(t.screen.modes.cursor_blink);
    t.feed("\x1b]11;?\x07");
    try std.testing.expectEqualStrings("\x1b]11;rgb:1e1e/1e1e/1e1e\x1b\\", t.pendingReplies());
}

test "titles, links, the bell and the clipboard policy" {
    var recorder: Recorder = .{};
    const handler: Handler = .{ .context = &recorder, .call = Recorder.call };
    var t = try Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 20, .rows = 2 }, .handler = handler });
    defer t.deinit();
    t.feed("\x1b]0;my title\x07\x07\x1b]8;;https://example.com/a;b\x1b\\link\x1b]8;;\x1b\\ plain");
    try std.testing.expectEqualStrings("my title", t.title());
    try std.testing.expectEqual(@as(usize, 1), recorder.titles);
    try std.testing.expectEqual(@as(usize, 1), recorder.bells);
    const linked = t.screen.row(0)[0].style.link;
    try std.testing.expect(linked != 0);
    try std.testing.expectEqualStrings("https://example.com/a;b", t.screen.link(linked).?);
    try std.testing.expectEqual(@as(u16, 0), t.screen.row(0)[5].style.link);
    // Clipboard requests are refused by default.
    t.feed("\x1b]52;c;aGVsbG8=\x07\x1b]52;c;?\x07");
    try std.testing.expectEqual(@as(usize, 0), recorder.written_len);
    try std.testing.expectEqual(@as(usize, 0), recorder.reads);

    var allowed = try Terminal.init(std.testing.allocator, .{ .handler = handler, .clipboard = .{ .read = true, .write = true } });
    defer allowed.deinit();
    allowed.feed("\x1b]52;c;aGVsbG8=\x07\x1b]52;c;?\x07");
    try std.testing.expectEqualStrings("hello", recorder.written[0..recorder.written_len]);
    try std.testing.expectEqual(@as(usize, 1), recorder.reads);
    allowed.answerClipboard("hi");
    try std.testing.expectEqualStrings("\x1b]52;c;aGk=\x1b\\", allowed.pendingReplies());
}

test "palette and color specs" {
    try std.testing.expectEqual(@as(?u24, 0xff8000), parseColor("rgb:ff/80/00"));
    try std.testing.expectEqual(@as(?u24, 0xff8000), parseColor("rgb:ffff/8080/0000"));
    try std.testing.expectEqual(@as(?u24, 0xff0000), parseColor("rgb:f/0/0"));
    try std.testing.expectEqual(@as(?u24, 0x123456), parseColor("#123456"));
    try std.testing.expectEqual(@as(?u24, null), parseColor("blue"));
    try std.testing.expectEqual(@as(u24, 0x5f87af), default_palette[67]);
    try std.testing.expectEqual(@as(u24, 0xeeeeee), default_palette[255]);
    var t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.feed("\x1b]4;1;#010203\x07\x1b]4;1;?\x07");
    try std.testing.expectEqual(@as(u24, 0x010203), t.palette[1]);
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:0101/0202/0303\x1b\\", t.pendingReplies());
    t.feed("\x1b]104\x07");
    try std.testing.expectEqual(default_palette[1], t.palette[1]);
}

test "a theme sets the defaults, and colors programs set stay until they reset" {
    var t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var palette = default_palette;
    palette[1] = 0x112233;
    palette[2] = 0x445566;
    t.feed("\x1b]4;2;#000002\x07\x1b]10;#0000ff\x07");
    t.setColors(0xeeeeee, 0x101010, 0xcccccc, palette);
    try std.testing.expectEqual(@as(u24, 0x112233), t.palette[1]);
    try std.testing.expectEqual(@as(u24, 0x000002), t.palette[2]);
    try std.testing.expectEqual(@as(u24, 0x0000ff), t.foreground);
    try std.testing.expectEqual(@as(u24, 0x101010), t.background);
    t.feed("\x1b]104;2\x07\x1b]110\x07");
    try std.testing.expectEqual(@as(u24, 0x445566), t.palette[2]);
    try std.testing.expectEqual(@as(u24, 0xeeeeee), t.foreground);
    t.feed("\x1b]11;#ffffff\x07\x1bc");
    try std.testing.expectEqual(@as(u24, 0x101010), t.background);
}

test "notifications and the pointer's shape" {
    const Seen = struct {
        title: [16]u8 = undefined,
        body: [16]u8 = undefined,
        count: usize = 0,
        fn call(context: ?*anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (event) {
                .notify => |n| {
                    @memcpy(self.title[0..n.title.len], n.title);
                    @memcpy(self.body[0..n.body.len], n.body);
                    self.count += 1;
                },
                else => {},
            }
        }
    };
    var seen: Seen = .{};
    var t = try Terminal.init(std.testing.allocator, .{ .handler = .{ .context = &seen, .call = Seen.call } });
    defer t.deinit();
    t.feed("\x1b]9;done\x07\x1b]9;4;1;50\x07\x1b]777;notify;Build;ok\x07");
    try std.testing.expectEqual(@as(usize, 2), seen.count);
    try std.testing.expectEqualStrings("Build", seen.title[0..5]);
    try std.testing.expectEqualStrings("ok", seen.body[0..2]);
    t.feed("\x1b]22;pointer\x07");
    try std.testing.expectEqualStrings("pointer", t.pointerShape());
    t.feed("\x1b[?1000h");
    try std.testing.expectEqualStrings("", t.pointerShape());
}

test "images through APC strings, per screen, gone as the screen clears" {
    var t = try Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 4 } });
    defer t.deinit();
    t.cell_width = 8;
    t.cell_height = 16;
    // 16 by 16 pixels: two cells by one, the cursor past them.
    const pixel = "AAAA";
    var text: [16 * 16 * 4 + 64]u8 = undefined;
    const head = "\x1b_Ga=T,f=24,s=16,v=16,i=3;";
    @memcpy(text[0..head.len], head);
    for (0..16 * 16) |i| @memcpy(text[head.len + i * 4 ..][0..4], pixel);
    const end = head.len + 16 * 16 * 4;
    @memcpy(text[end..][0..2], "\x1b\\");
    t.feed(text[0 .. end + 2]);
    try std.testing.expectEqualStrings("\x1b_Gi=3;OK\x1b\\", t.pendingReplies());
    t.clearReplies();
    try std.testing.expectEqual(@as(u16, 2), t.screen.cursor.x);
    try std.testing.expectEqual(@as(usize, 1), t.activeImages().placements.items.len);
    // The alternate screen has its own, none.
    t.feed("\x1b[?1049h");
    try std.testing.expectEqual(@as(usize, 0), t.activeImages().placements.items.len);
    t.feed("\x1b_Ga=p,i=3\x1b\\");
    try std.testing.expectEqualStrings("\x1b_Gi=3;ENOENT: image not found\x1b\\", t.pendingReplies());
    t.clearReplies();
    t.feed("\x1b[?1049l");
    try std.testing.expectEqual(@as(usize, 1), t.activeImages().placements.items.len);
    // Not an image command, or cancelled: nothing.
    t.feed("\x1b_Xyz\x1b\\\x1b_Ga=p,i=3\x18");
    try std.testing.expectEqual(@as(usize, 0), t.pendingReplies().len);
    try std.testing.expectEqual(@as(usize, 1), t.activeImages().placements.items.len);
    // Clearing the screen clears them.
    t.feed("\x1b[2J");
    try std.testing.expectEqual(@as(usize, 0), t.activeImages().images.items.len);
    var refused = try Terminal.init(std.testing.allocator, .{ .image_limit = 0 });
    defer refused.deinit();
    refused.feed("\x1b_Ga=q,i=1,s=1,v=1,f=24;AAAA\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), refused.pendingReplies().len);
}

test "a new width rewraps the screen; images and tracked positions move with their cells" {
    var t = try Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 8, .rows = 4 } });
    defer t.deinit();
    t.cell_width = 8;
    t.cell_height = 16;
    // A line wrapping once, then an image placed after it.
    t.feed("abcdefghij\r\n");
    t.feed("\x1b_Ga=T,f=24,s=1,v=1,i=4,q=2;AAAA\x1b\\");
    const placed = t.activeImages().placements.items[0];
    try std.testing.expectEqual(t.screen.screenRow(2), placed.row);
    var tracked = [_]screen_module.Position{.{ .row = t.screen.screenRow(1), .col = 1 }};
    try t.resize(12, 4, &tracked);
    // The line is one row now: the image and 'j' moved up with it.
    try std.testing.expectEqual(t.screen.screenRow(1), t.activeImages().placements.items[0].row);
    try std.testing.expectEqual(t.screen.screenRow(0), tracked[0].row);
    try std.testing.expectEqual(@as(u16, 9), tracked[0].col);
    try std.testing.expectEqual(@as(u21, 'j'), t.screen.row(0)[9].cp);
}
