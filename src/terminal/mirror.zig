//! What a terminal shows, as VT sequences for another terminal to show.
//!
//! A `Mirror` frames a terminal no view shows, as a server's that keeps a
//! session running for windows in other processes: `frame` writes what
//! brings a terminal showing the frames before to what this one shows now.
//! The other terminal reads them as if a program wrote them, and shows the
//! screen and the scrollback cell for cell, the cursor, the modes that
//! change what it sends (the cursor keys', the keypad's, the mouse's,
//! focus, bracketed paste), the colors programs set, the title and the
//! images; it never lays out a program's output itself, so it cannot come
//! to show something else.
//!
//! Frames draw rows where they are, and rows that scroll off pass through
//! the other screen in order, so that its scrollback is this one's; soft
//! wraps stay soft. The first frame, and one after the size changed, start
//! the other terminal over. A frame does not come while a program holds a
//! synchronized update (mode 2026), for up to a second: `frame` then says
//! that one is due.
//!
//! `snapshot` writes all a terminal shows, for a new terminal of the same
//! size to show the same; `history` its scrollback and screen down to the
//! cursor, for a terminal that takes a session over after its program
//! ended.
const std = @import("std");
const terminal_module = @import("terminal.zig");
const screen_module = @import("screen.zig");
const graphics = @import("graphics.zig");

const Terminal = terminal_module.Terminal;
const Screen = screen_module.Screen;
const Cell = screen_module.Cell;
const Style = screen_module.Style;
const Color = screen_module.Color;
const Out = std.ArrayList(u8);

/// How long a synchronized update holds frames back.
pub const sync_timeout_ms = 1000;

/// A row as frames draw it.
const Line = struct {
    /// Its cells up to the last that holds something, each in its own
    /// style, an empty cell in none.
    vt: []const u8 = "",
    /// Columns that hold something: text, a style or a background.
    end: usize = 0,
    /// It soft-wraps into the next row.
    wrap: bool = false,
    /// A wide character that did not fit at its end went on to the next.
    short: bool = false,
    starts_wide: bool = false,

    fn key(self: Line, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.vt.len + 1);
        out[0] = @intFromBool(self.wrap);
        @memcpy(out[1..], self.vt);
        return out;
    }
    fn sameKey(self: Line, k: []const u8) bool {
        return k.len == self.vt.len + 1 and k[0] == @intFromBool(self.wrap) and std.mem.eql(u8, k[1..], self.vt);
    }
};

const RowView = struct { cells: []const Cell, wrapped: bool };

fn readLine(allocator: std.mem.Allocator, screen: *const Screen, row: ?RowView) !Line {
    const r = row orelse return .{};
    const cells = r.cells;
    var line: Line = .{ .wrap = r.wrapped };
    for (cells, 0..) |c, x| {
        if (c.cp != 0 or c.wide == .spacer or !defaultStyle(c.style)) line.end = x + 1;
    }
    if (cells.len > 0) {
        line.short = r.wrapped and cells[cells.len - 1].cp == 0 and cells[cells.len - 1].wide == .narrow;
        line.starts_wide = cells[0].wide == .wide;
    }
    var out: Out = .empty;
    errdefer out.deinit(allocator);
    var sgr_bytes: [128]u8 = undefined;
    var current: []const u8 = sgr_reset;
    var current_bytes: [128]u8 = undefined;
    var link: u16 = 0;
    for (cells[0..line.end]) |c| {
        if (c.wide == .spacer) continue;
        const want = sgrOf(&sgr_bytes, c.style);
        if (!std.mem.eql(u8, want, current)) {
            try out.appendSlice(allocator, want);
            @memcpy(current_bytes[0..want.len], want);
            current = current_bytes[0..want.len];
        }
        if (c.style.link != link) {
            try out.print(allocator, "\x1b]8;;{s}\x1b\\", .{if (c.style.link != 0) screen.link(c.style.link) orelse "" else ""});
            link = c.style.link;
        }
        if (c.cp == 0) {
            try out.append(allocator, ' ');
        } else {
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c.cp, &utf8) catch 0;
            try out.appendSlice(allocator, utf8[0..n]);
        }
    }
    if (link != 0) try out.appendSlice(allocator, "\x1b]8;;\x1b\\");
    if (!std.mem.eql(u8, current, sgr_reset)) try out.appendSlice(allocator, sgr_reset);
    line.vt = try out.toOwnedSlice(allocator);
    return line;
}

const sgr_reset = "\x1b[0m";

fn defaultStyle(style: Style) bool {
    return Style.eql(style, .{ .link = style.link }) and style.link == 0;
}

/// The SGR that sets a style from nothing.
fn sgrOf(buffer: []u8, style: Style) []const u8 {
    var plain = style;
    plain.link = 0;
    if (Style.eql(plain, .{})) return sgr_reset;
    var w: std.Io.Writer = .fixed(buffer);
    w.writeAll("\x1b[0") catch {};
    const a = style.attrs;
    if (a.bold) w.writeAll(";1") catch {};
    if (a.dim) w.writeAll(";2") catch {};
    if (a.italic) w.writeAll(";3") catch {};
    switch (a.underline) {
        .none => {},
        .single => w.writeAll(";4") catch {},
        .double => w.writeAll(";4:2") catch {},
        .curly => w.writeAll(";4:3") catch {},
        .dotted => w.writeAll(";4:4") catch {},
        .dashed => w.writeAll(";4:5") catch {},
    }
    if (a.blink) w.writeAll(";5") catch {};
    if (a.inverse) w.writeAll(";7") catch {};
    if (a.hidden) w.writeAll(";8") catch {};
    if (a.strike) w.writeAll(";9") catch {};
    if (a.overline) w.writeAll(";53") catch {};
    color(&w, style.fg, 30, 90, 38);
    color(&w, style.bg, 40, 100, 48);
    color(&w, style.underline_color, 0, 0, 58);
    w.writeAll("m") catch {};
    return w.buffered();
}

fn color(w: *std.Io.Writer, c: Color, base: u8, bright: u8, extended: u8) void {
    switch (c.kind) {
        .default => {},
        .palette => {
            const i: u8 = @truncate(c.value);
            if (base != 0 and i < 8) {
                w.print(";{d}", .{base + i}) catch {};
            } else if (base != 0 and i < 16) {
                w.print(";{d}", .{bright + i - 8}) catch {};
            } else w.print(";{d};5;{d}", .{ extended, i }) catch {};
        },
        .rgb => w.print(";{d};2;{d};{d};{d}", .{ extended, @as(u8, @truncate(c.value >> 16)), @as(u8, @truncate(c.value >> 8)), @as(u8, @truncate(c.value)) }) catch {},
    }
}

/// Rows `from..to` by absolute row, of the primary screen when `primary`,
/// else of the screen that shows; rows gone draw empty.
fn readLines(allocator: std.mem.Allocator, screen: *const Screen, from: u64, to: u64, primary: bool) ![]Line {
    const lines = try allocator.alloc(Line, @intCast(to -| from));
    for (lines, 0..) |*line, i| {
        const abs = from + i;
        const row = if (primary) screen.primaryRowAt(abs) else screen.rowAt(abs);
        line.* = try readLine(allocator, screen, if (row) |r| .{ .cells = r.cells, .wrapped = r.wrapped } else null);
    }
    return lines;
}

/// The modes the other terminal takes: those that change what it sends,
/// and how it draws. Those off go first: the mouse's events and format
/// are one setting each, which setting one of their modes picks and
/// resetting any sets back.
const mirrored_modes = [_]u16{ 1, 66, 1004, 1007, 2004, 9, 1000, 1002, 1003, 1005, 1006, 1015, 1016, 5 };

/// A placement as a mirror placed it in the other terminal.
const ImageKey = struct {
    image: u32,
    id: u64,
    row: u64,
    col: u16,
    x_offset: u32,
    y_offset: u32,
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
    cols: u32,
    rows: u32,
    /// The rows it takes.
    span: u32,
    z: i32,
};

/// The images a mirror sent of a screen, at their generations, and the
/// placements it made, with their ids in the other terminal.
const Images = struct {
    gens: std.ArrayList(struct { id: u32, generation: u64 }) = .empty,
    placed: std.ArrayList(struct { key: ImageKey, id: u32 }) = .empty,

    fn deinit(self: *Images, allocator: std.mem.Allocator) void {
        self.gens.deinit(allocator);
        self.placed.deinit(allocator);
    }
    fn clear(self: *Images) void {
        self.gens.clearRetainingCapacity();
        self.placed.clearRetainingCapacity();
    }
    fn generation(self: *const Images, id: u32) ?u64 {
        for (self.gens.items) |g| if (g.id == id) return g.generation;
        return null;
    }
    fn isPlaced(self: *const Images, key: ImageKey) bool {
        for (self.placed.items) |p| if (std.meta.eql(p.key, key)) return true;
        return false;
    }
};

pub const Mirror = struct {
    allocator: std.mem.Allocator,
    terminal: *Terminal,
    /// A frame went; the size it drew, and whether it showed the alternate
    /// screen.
    started: bool = false,
    cols: u16 = 0,
    rows: u16 = 0,
    alternate: bool = false,
    /// The screen's lines pushed into the scrollback, and the times the
    /// scrollback was cleared, at the last frame.
    pushed: u64 = 0,
    clears: u64 = 0,
    /// How each row of the screen was drawn, and the main screen's while
    /// the alternate one shows.
    sent: std.ArrayList(?[]u8) = .empty,
    main: std.ArrayList(?[]u8) = .empty,
    /// What the last frame set of these.
    modes: Out = .empty,
    colors: Out = .empty,
    cursor: Out = .empty,
    title: Out = .empty,
    images: [2]Images = .{ .{}, .{} },
    placement: u32 = 0,
    clipboard_writes: u64,
    held_since: ?i64 = null,
    /// Draw the main screen too when starting over on the alternate one,
    /// as a snapshot does.
    with_main: bool = false,

    /// A mirror of `terminal`, whose first frame starts the other terminal
    /// over. Programs' writes to the clipboard from now on go on with the
    /// frames.
    pub fn init(allocator: std.mem.Allocator, terminal: *Terminal) Mirror {
        return .{ .allocator = allocator, .terminal = terminal, .clipboard_writes = terminal.clipboard_writes };
    }

    pub fn deinit(self: *Mirror) void {
        freeRows(self.allocator, &self.sent);
        freeRows(self.allocator, &self.main);
        self.sent.deinit(self.allocator);
        self.main.deinit(self.allocator);
        self.modes.deinit(self.allocator);
        self.colors.deinit(self.allocator);
        self.cursor.deinit(self.allocator);
        self.title.deinit(self.allocator);
        for (&self.images) |*i| i.deinit(self.allocator);
    }

    /// Have the next frame start the other terminal over, as when another
    /// terminal shows the frames from now.
    pub fn reset(self: *Mirror) void {
        self.started = false;
    }

    /// Append what brings the other terminal to what this one shows to
    /// `out`, nothing when it shows it already. True when a frame is due
    /// later instead, as a synchronized update holds it back; `now_ms` is
    /// the time in milliseconds.
    pub fn frame(self: *Mirror, out: *Out, now_ms: i64) !bool {
        const s = &self.terminal.screen;
        if (s.modes.synchronized) {
            const since = self.held_since orelse now_ms;
            self.held_since = since;
            if (now_ms - since < sync_timeout_ms) return true;
        } else self.held_since = null;
        try self.draw(out);
        return false;
    }

    fn draw(self: *Mirror, out: *Out) !void {
        const allocator = self.allocator;
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const t = self.terminal;
        const s = &t.screen;
        const start = out.items.len;
        const alternate = s.onAlternate();
        const clears = s.history.clears;
        const screen = try readLines(arena, s, s.screenRow(0), s.screenRow(s.rows), false);
        if (!self.started or s.cols != self.cols or s.rows != self.rows) {
            try self.restart(out, arena, screen, alternate);
        } else if (alternate != self.alternate) {
            if (s.pushed != self.pushed or clears != self.clears) {
                // Rows went to the scrollback or it was cleared just
                // before the screens switched: start over.
                try self.restart(out, arena, screen, alternate);
            } else if (alternate) {
                try out.appendSlice(allocator, "\x1b[?1049h");
                std.mem.swap(std.ArrayList(?[]u8), &self.main, &self.sent);
                try self.blankRows(screen.len);
                try self.redraw(out, arena, screen);
            } else {
                try out.appendSlice(allocator, "\x1b[?1049l");
                freeRows(allocator, &self.sent);
                std.mem.swap(std.ArrayList(?[]u8), &self.main, &self.sent);
                try self.redraw(out, arena, screen);
            }
        } else if (!alternate) {
            if (clears != self.clears) try out.appendSlice(allocator, "\x1b[3J");
            if (s.pushed > self.pushed) {
                // Rows went to the scrollback: those still there pass
                // through the other screen's top in order, then the screen.
                const scrolled = try readLines(arena, s, @max(self.pushed, s.firstRow()), s.pushed, false);
                try self.write(out, arena, try std.mem.concat(arena, Line, &.{ scrolled, screen }));
            } else try self.redraw(out, arena, screen);
        } else try self.redraw(out, arena, screen);
        self.started = true;
        self.cols = s.cols;
        self.rows = s.rows;
        self.alternate = alternate;
        self.pushed = s.pushed;
        self.clears = clears;
        try self.sendImages(out, arena);
        try self.state(out, start);
    }

    /// Size `sent` to the screen's rows, none drawn.
    fn blankRows(self: *Mirror, rows: usize) !void {
        freeRows(self.allocator, &self.sent);
        try self.sent.appendNTimes(self.allocator, null, rows);
    }

    /// Start the other terminal over: no images, an empty screen and
    /// scrollback, then this one's, row by row.
    fn restart(self: *Mirror, out: *Out, arena: std.mem.Allocator, screen: []const Line, alternate: bool) !void {
        const no_images = "\x1b_Ga=d,d=A,q=2\x1b\\";
        try out.appendSlice(self.allocator, "\x1b[?1049h" ++ no_images ++ "\x1b[?1049l" ++ no_images ++ "\x1b[0m\x1b[H\x1b[2J\x1b[3J");
        self.modes.clearRetainingCapacity();
        self.cursor.clearRetainingCapacity();
        for (&self.images) |*i| i.clear();
        freeRows(self.allocator, &self.main);
        self.main.clearRetainingCapacity();
        try self.blankRows(screen.len);
        const s = &self.terminal.screen;
        if (alternate) {
            if (self.with_main) {
                const main = try readLines(arena, s, s.firstRow(), s.pushed + s.rows, true);
                try self.write(out, arena, main);
                // The rows the main screen's frame drew are not kept: the
                // alternate screen's are.
                try self.blankRows(screen.len);
            }
            // A full-screen program's main screen is not drawn otherwise:
            // the other terminal starts over when the program ends.
            try out.appendSlice(self.allocator, "\x1b[?1049h");
            try self.redraw(out, arena, screen);
            return;
        }
        const scrollback = try readLines(arena, s, s.firstRow(), s.pushed, false);
        try self.write(out, arena, try std.mem.concat(arena, Line, &.{ scrollback, screen }));
    }

    /// Draw lines one after another from the other screen's top, so that
    /// those before its last rows go to its scrollback, as they went here.
    fn write(self: *Mirror, out: *Out, arena: std.mem.Allocator, lines: []const Line) !void {
        const rows = self.sent.items.len;
        const first_shown = lines.len -| rows;
        try out.appendSlice(self.allocator, "\x1b[H");
        for (lines, 0..) |line, i| {
            const last = i + 1 == lines.len;
            try self.row(out, line, if (last) null else lines[i + 1], i > 0 and lines[i - 1].wrap);
            if (i >= first_shown) try self.setSent(i - first_shown, line);
            if (!last and !line.wrap) try out.appendSlice(self.allocator, "\r\n");
        }
        _ = arena;
    }

    /// Draw again the rows that changed, and those of the soft-wrapped
    /// lines they are in, from their lines' first rows.
    fn redraw(self: *Mirror, out: *Out, arena: std.mem.Allocator, screen: []const Line) !void {
        _ = arena;
        if (self.sent.items.len != screen.len) try self.blankRows(screen.len);
        var y: usize = 0;
        while (y < screen.len) : (y += 1) {
            if (self.sent.items[y]) |k| if (screen[y].sameKey(k)) continue;
            var first = y;
            while (first > 0 and screen[first - 1].wrap) first -= 1;
            try out.print(self.allocator, "\x1b[{d}H", .{first + 1});
            var at = first;
            while (at < screen.len) : (at += 1) {
                const next: ?Line = if (at + 1 < screen.len and screen[at].wrap) screen[at + 1] else null;
                try self.row(out, screen[at], next, at > first);
                try self.setSent(at, screen[at]);
                if (next == null) break;
            }
            y = at;
        }
    }

    fn setSent(self: *Mirror, y: usize, line: Line) !void {
        if (y >= self.sent.items.len) return;
        const k = try line.key(self.allocator);
        if (self.sent.items[y]) |old| self.allocator.free(old);
        self.sent.items[y] = k;
    }

    /// Draw a line from the cursor's column 0: whole, clearing what was
    /// after it, or, soft wrapped into `next`, out to its last column for
    /// the other terminal to wrap it too. A row a soft wrap continues,
    /// `cont`, starts with the cursor waiting to wrap at the end of the
    /// row before, which a clear would clear instead: with nothing on it,
    /// a blank wraps there first and the clear after takes it.
    fn row(self: *Mirror, out: *Out, line: Line, next: ?Line, cont: bool) !void {
        const allocator = self.allocator;
        const cols: usize = self.terminal.screen.cols;
        try out.appendSlice(allocator, sgr_reset);
        if (!cont) {
            try out.appendSlice(allocator, "\x1b[2K");
        } else if (line.vt.len == 0) try out.appendSlice(allocator, " \r");
        try out.appendSlice(allocator, line.vt);
        try out.appendSlice(allocator, sgr_reset);
        if (line.wrap and next != null) {
            // Short of the last column when a wide character did not fit
            // there, for the other terminal to wrap it too.
            const to = if (line.short and next.?.starts_wide) cols - 1 else cols;
            if (line.end < to) try out.appendNTimes(allocator, ' ', to - line.end);
        } else if (line.end < cols) try out.appendSlice(allocator, "\x1b[K");
    }

    /// Bring the other terminal's images of the screen that shows to this
    /// one's: send the pixels of those placed, once for each generation,
    /// place what shows that is not, delete what went. A placement whose
    /// top scrolled off before a frame saw it does not show there.
    fn sendImages(self: *Mirror, out: *Out, arena: std.mem.Allocator) !void {
        const allocator = self.allocator;
        const t = self.terminal;
        const s = &t.screen;
        const alternate = s.onAlternate();
        const mine = &self.images[@intFromBool(alternate)];
        const storage = &t.images[@intFromBool(alternate)];
        const top = graphics.Storage.top(s);
        var seen: std.ArrayList(ImageKey) = .empty;
        var place: std.ArrayList(ImageKey) = .empty;
        for (storage.placements.items) |p| {
            if (p.virtual) continue;
            const image = storage.image(p.image_id) orelse continue;
            const size = graphics.layout(p, image.*, t.cell_width, t.cell_height);
            const span = @max(size.rows, 1);
            if (p.row + span <= top or p.row >= top + s.rows) continue;
            const k: ImageKey = .{ .image = p.image_id, .id = p.id, .row = p.row, .col = p.col, .x_offset = p.x_offset, .y_offset = p.y_offset, .src_x = p.src_x, .src_y = p.src_y, .src_w = p.src_w, .src_h = p.src_h, .cols = p.cols, .rows = p.rows, .span = span, .z = p.z };
            try seen.append(arena, k);
            if (!mine.isPlaced(k) and p.row >= top) try place.append(arena, k);
        }
        const isSeen = struct {
            fn call(list: []const ImageKey, k: ImageKey) bool {
                for (list) |x| if (std.meta.eql(x, k)) return true;
                return false;
            }
        }.call;
        // Images gone, or of new pixels, which the other terminal's
        // placements of may not survive: placed again where they show.
        var g: usize = 0;
        while (g < mine.gens.items.len) {
            const entry = mine.gens.items[g];
            const now: u64 = if (storage.image(entry.id)) |i| i.generation else 0;
            if (now == entry.generation) {
                g += 1;
                continue;
            }
            if (now == 0) {
                try out.print(allocator, "\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{entry.id});
                _ = mine.gens.swapRemove(g);
            } else g += 1;
            var i: usize = 0;
            while (i < mine.placed.items.len) {
                const k = mine.placed.items[i].key;
                if (k.image != entry.id) {
                    i += 1;
                    continue;
                }
                _ = mine.placed.swapRemove(i);
                if (now != 0 and isSeen(seen.items, k) and k.row >= top and !isSeen(place.items, k)) try place.append(arena, k);
            }
        }
        // Placements gone from where they would show; those that scrolled
        // off stay, as they do here.
        var i: usize = 0;
        while (i < mine.placed.items.len) {
            const p = mine.placed.items[i];
            if (!isSeen(seen.items, p.key) and p.key.row + p.key.span > top and p.key.row < top + s.rows) {
                try out.print(allocator, "\x1b_Ga=d,d=i,i={d},p={d},q=2\x1b\\", .{ p.key.image, p.id });
                _ = mine.placed.swapRemove(i);
            } else i += 1;
        }
        for (place.items) |k| {
            const image = storage.image(k.image) orelse continue;
            if (mine.generation(k.image) != image.generation) {
                try sendImage(allocator, out, image.*);
                var found = false;
                for (mine.gens.items) |*entry| if (entry.id == k.image) {
                    entry.generation = image.generation;
                    found = true;
                };
                if (!found) try mine.gens.append(allocator, .{ .id = k.image, .generation = image.generation });
            }
            self.placement += 1;
            try out.print(allocator, "\x1b[{d};{d}H\x1b_Ga=p,i={d},p={d},X={d},Y={d},x={d},y={d},w={d},h={d},c={d},r={d},z={d},C=1,q=2\x1b\\", .{ k.row - top + 1, @as(u32, k.col) + 1, k.image, self.placement, k.x_offset, k.y_offset, k.src_x, k.src_y, k.src_w, k.src_h, k.cols, k.rows, k.z });
            try mine.placed.append(allocator, .{ .key = k, .id = self.placement });
        }
    }

    /// Set the modes, the colors, the title and the cursor where they
    /// changed, and pass on programs' uses of the clipboard. `start` is
    /// where this frame began in `out`.
    fn state(self: *Mirror, out: *Out, start: usize) !void {
        const allocator = self.allocator;
        const t = self.terminal;
        const s = &t.screen;
        var buffer: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        for ([_]bool{ false, true }) |on| for (mirrored_modes) |mode| {
            if ((t.privateModeState(mode) == 1) != on) continue;
            try w.print("\x1b[?{d}{c}", .{ mode, @as(u8, if (on) 'h' else 'l') });
        };
        try w.print("\x1b]22;{s}\x1b\\", .{t.pointerShape()});
        try replaceIfChanged(allocator, out, &self.modes, w.buffered());

        var colors: Out = .empty;
        defer colors.deinit(allocator);
        const defaults = [_]struct { code: u8, value: u24, set: bool }{
            .{ .code = 10, .value = t.foreground, .set = t.foreground_set },
            .{ .code = 11, .value = t.background, .set = t.background_set },
            .{ .code = 12, .value = t.cursor_color, .set = t.cursor_set },
        };
        for (defaults) |d| {
            if (d.set) try printColor(allocator, &colors, "{d}", d.code, d.value) else try colors.print(allocator, "\x1b]1{d}\x1b\\", .{d.code});
        }
        try colors.appendSlice(allocator, "\x1b]104\x1b\\");
        for (0..256) |index| if (t.palette_set.isSet(index)) try printColor(allocator, &colors, "4;{d}", index, t.palette[index]);
        try replaceIfChanged(allocator, out, &self.colors, colors.items);

        if (!std.mem.eql(u8, t.title(), self.title.items)) {
            try out.print(allocator, "\x1b]2;{s}\x1b\\", .{t.title()});
            self.title.clearRetainingCapacity();
            try self.title.appendSlice(allocator, t.title());
        }
        if (t.clipboard_writes != self.clipboard_writes) {
            self.clipboard_writes = t.clipboard_writes;
            const text = t.clipboard_storage[0..t.clipboard_len];
            const encoder = std.base64.standard.Encoder;
            try out.appendSlice(allocator, "\x1b]52;c;");
            const at = out.items.len;
            try out.resize(allocator, at + encoder.calcSize(text.len));
            _ = encoder.encode(out.items[at..], text);
            try out.appendSlice(allocator, "\x1b\\");
        }
        // Programs' reads go to the first mirror to frame.
        for (t.forwarded_reads[0..t.forwarded_len]) |selection| try out.print(allocator, "\x1b]52;{c};?\x1b\\", .{selection});
        t.forwarded_len = 0;

        // The cursor's shape as programs left it is the other terminal's
        // default (DECSCUSR 0), which its own options make.
        const m = s.modes;
        const shape: u8 = if (m.cursor_shape == .block and !m.cursor_blink) 0 else switch (m.cursor_shape) {
            .block => if (m.cursor_blink) 1 else 2,
            .underline => if (m.cursor_blink) 3 else 4,
            .bar => if (m.cursor_blink) 5 else 6,
        };
        var cursor_bytes: [64]u8 = undefined;
        const cursor = try std.fmt.bufPrint(&cursor_bytes, "\x1b[0m\x1b[{d};{d}H\x1b[?25{c}\x1b[{d} q", .{ s.cursor.y + 1, s.cursor.x + 1, @as(u8, if (m.cursor_visible) 'h' else 'l'), shape });
        // After rows the cursor goes back, though it did not move.
        if (!std.mem.eql(u8, cursor, self.cursor.items) or out.items.len > start) {
            try out.appendSlice(allocator, cursor);
            self.cursor.clearRetainingCapacity();
            try self.cursor.appendSlice(allocator, cursor);
        }
    }
};

fn replaceIfChanged(allocator: std.mem.Allocator, out: *Out, last: *Out, now: []const u8) !void {
    if (std.mem.eql(u8, now, last.items)) return;
    try out.appendSlice(allocator, now);
    last.clearRetainingCapacity();
    try last.appendSlice(allocator, now);
}

fn printColor(allocator: std.mem.Allocator, out: *Out, comptime code: []const u8, number: anytype, value: u24) !void {
    try out.print(allocator, "\x1b]" ++ code ++ ";rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ number, @as(u8, @truncate(value >> 16)), @as(u8, @truncate(value >> 8)), @as(u8, @truncate(value)) });
}

fn freeRows(allocator: std.mem.Allocator, rows: *std.ArrayList(?[]u8)) void {
    for (rows.items) |r| if (r) |k| allocator.free(k);
    rows.clearRetainingCapacity();
}

/// The sequences that send an image's pixels, as RGBA, in chunks.
fn sendImage(allocator: std.mem.Allocator, out: *Out, image: graphics.Image) !void {
    var rgba = image.pixels;
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);
    if (image.format == .rgb) {
        const converted = try allocator.alloc(u8, @as(usize, image.width) * image.height * 4);
        owned = converted;
        for (0..@as(usize, image.width) * image.height) |i| {
            converted[i * 4 ..][0..4].* = .{ image.pixels[i * 3], image.pixels[i * 3 + 1], image.pixels[i * 3 + 2], 255 };
        }
        rgba = converted;
    }
    const encoder = std.base64.standard.Encoder;
    const data = try allocator.alloc(u8, encoder.calcSize(rgba.len));
    defer allocator.free(data);
    _ = encoder.encode(data, rgba);
    const chunk = 4096;
    var at: usize = 0;
    while (true) {
        const part = data[at..@min(at + chunk, data.len)];
        const more: u8 = if (at + chunk < data.len) 1 else 0;
        if (at == 0) {
            try out.print(allocator, "\x1b_Ga=t,f=32,s={d},v={d},i={d},q=2,m={d};{s}\x1b\\", .{ image.width, image.height, image.id, more, part });
        } else try out.print(allocator, "\x1b_Gm={d};{s}\x1b\\", .{ more, part });
        at += chunk;
        if (at >= data.len) break;
    }
}

/// All a terminal shows as VT sequences: its scrollback and screens with
/// their styles, its images, the cursor, the modes programs set, the
/// colors and the title. Fed to a new terminal of the same size, it shows
/// the same. The caller owns the bytes.
pub fn snapshot(allocator: std.mem.Allocator, terminal: *Terminal) ![]u8 {
    var m = Mirror.init(allocator, terminal);
    defer m.deinit();
    m.with_main = true;
    // Clipboard writes are not part of what shows.
    m.clipboard_writes = terminal.clipboard_writes;
    const forwarded = terminal.forwarded_len;
    var out: Out = .empty;
    errdefer out.deinit(allocator);
    try m.draw(&out);
    terminal.forwarded_len = forwarded;
    const s = &terminal.screen;
    // What changes how later output lays out.
    if (!s.modes.autowrap) try out.appendSlice(allocator, "\x1b[?7l");
    if (s.modes.insert) try out.appendSlice(allocator, "\x1b[4h");
    if (s.modes.newline) try out.appendSlice(allocator, "\x1b[20h");
    for (s.cursor.charsets, 0..) |charset, slot| {
        if (charset == .ascii) continue;
        try out.print(allocator, "\x1b{c}{c}", .{ @as(u8, if (slot == 0) '(' else ')'), @as(u8, if (charset == .dec_graphics) '0' else 'A') });
    }
    if (s.cursor.shift == 1) try out.append(allocator, 0x0e);
    return out.toOwnedSlice(allocator);
}

/// The scrollback and the screen down to the cursor's row, or to the last
/// row with something on it when that is above, as rows of VT sequences
/// without the cursor and the modes: fed to a terminal of the same width,
/// it leaves the cursor below what it shows, for the next program to start
/// under it. A full-screen program's screen has none: null while the
/// alternate screen shows. The caller owns the bytes.
pub fn history(allocator: std.mem.Allocator, terminal: *Terminal) !?[]u8 {
    const s = &terminal.screen;
    if (s.onAlternate()) return null;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try readLines(arena, s, s.firstRow(), s.pushed + s.rows, false);
    var out: Out = .empty;
    errdefer out.deinit(allocator);
    // The last line, down to the cursor's.
    var end: isize = @intCast(@min(s.pushed - s.firstRow() + s.cursor.y, lines.len - 1));
    while (end >= 0 and lines[@intCast(end)].end == 0) end -= 1;
    if (end < 0) return try out.toOwnedSlice(allocator);
    const last: usize = @intCast(end);
    for (lines[0 .. last + 1], 0..) |line, i| {
        try out.appendSlice(allocator, line.vt);
        try out.appendSlice(allocator, sgr_reset);
        if (line.wrap and i < last) {
            const to = if (line.short and lines[i + 1].starts_wide) s.cols - 1 else s.cols;
            if (line.end < to) try out.appendNTimes(allocator, ' ', to - line.end);
            continue;
        }
        try out.appendSlice(allocator, "\r\n");
    }
    return try out.toOwnedSlice(allocator);
}

// ---- Tests -----------------------------------------------------------------

fn rowText(t: *const Terminal, abs: u64, buffer: []u8) []const u8 {
    const r = t.screen.rowAt(abs) orelse return "";
    var len: usize = 0;
    for (r.cells) |c| {
        if (c.wide == .spacer) continue;
        len += std.unicode.utf8Encode(if (c.cp == 0) ' ' else c.cp, buffer[len..]) catch 0;
    }
    return std.mem.trimEnd(u8, buffer[0..len], " ");
}

/// The other terminal shows what the mirrored one does, row by row from
/// the top of the scrollback, with the same styles and wraps.
fn expectSame(a: *const Terminal, b: *const Terminal) !void {
    const sa = &a.screen;
    const sb = &b.screen;
    try std.testing.expectEqual(sa.cols, sb.cols);
    try std.testing.expectEqual(sa.onAlternate(), sb.onAlternate());
    if (!sa.onAlternate()) try std.testing.expectEqual(sa.history.count, sb.history.count);
    const rows = (if (sa.onAlternate()) 0 else sa.history.count) + sa.rows;
    var ba: [512]u8 = undefined;
    var bb: [512]u8 = undefined;
    for (0..rows) |i| {
        const ra = (if (sa.onAlternate()) sa.pushed else sa.firstRow()) + i;
        const rb = (if (sb.onAlternate()) sb.pushed else sb.firstRow()) + i;
        try std.testing.expectEqualStrings(rowText(a, ra, &ba), rowText(b, rb, &bb));
        const ca = sa.rowAt(ra).?;
        const cb = sb.rowAt(rb).?;
        try std.testing.expectEqual(ca.wrapped, cb.wrapped);
        for (ca.cells, 0..) |cell, x| {
            if (x >= cb.cells.len) break;
            var plain_a = cell.style;
            var plain_b = cb.cells[x].style;
            try std.testing.expectEqual(plain_a.link != 0, plain_b.link != 0);
            plain_a.link = 0;
            plain_b.link = 0;
            try std.testing.expect(Style.eql(plain_a, plain_b));
        }
    }
    try std.testing.expectEqual(sa.cursor.x, sb.cursor.x);
    try std.testing.expectEqual(sa.cursor.y, sb.cursor.y);
}

const Pair = struct {
    server: Terminal,
    client: Terminal,
    mirror: Mirror = undefined,
    out: Out = .empty,

    fn init(self: *Pair, cols: u16, rows: u16) !void {
        const options: terminal_module.Options = .{ .screen = .{ .cols = cols, .rows = rows, .scrollback = 50, .scrollback_cells = 5000 }, .clipboard = .{ .forward_read = true } };
        self.* = .{ .server = try Terminal.init(std.testing.allocator, options), .client = try Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = cols, .rows = rows, .scrollback = 50, .scrollback_cells = 5000 } }) };
        self.mirror = Mirror.init(std.testing.allocator, &self.server);
    }
    fn deinit(self: *Pair) void {
        self.mirror.deinit();
        self.out.deinit(std.testing.allocator);
        self.server.deinit();
        self.client.deinit();
    }
    /// Feed the server, frame, and feed the frame to the client; the frame.
    fn step(self: *Pair, bytes: []const u8) ![]const u8 {
        self.server.feed(bytes);
        self.server.clearReplies();
        self.out.clearRetainingCapacity();
        try std.testing.expect(!try self.mirror.frame(&self.out, 0));
        self.client.feed(self.out.items);
        try expectSame(&self.server, &self.client);
        return self.out.items;
    }
};

test "frames bring the other terminal to the screen and scrollback, cell for cell" {
    var p: Pair = undefined;
    try p.init(10, 3);
    defer p.deinit();
    _ = try p.step("one\r\n\x1b[1;31mtwo\x1b[0m\r\nthree");
    // Nothing changed: only the cursor would go, and it did not.
    try std.testing.expectEqualStrings("", try p.step(""));
    // Rows scroll into the scrollback, in order.
    _ = try p.step("\r\nfour\r\nfive\r\nsix");
    try std.testing.expectEqual(@as(usize, 3), p.client.screen.history.count);
    // Soft wraps stay soft, wide characters and links keep their cells.
    _ = try p.step("\r\nabcdefghijklm\x1b]8;;https://a.b\x1b\\link\x1b]8;;\x1b\\");
    _ = try p.step("\r\n123456789\xe4\xb8\xad\xe6\x96\x87");
    try std.testing.expect(p.client.screen.wrapped(p.client.screen.cursor.y - 1));
    // A row changing in place redraws alone.
    const frame = try p.step("\x1b[2;1H\x1b[44mX\x1b[0m");
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[2J") == null);
    // Clearing the scrollback, then a full-screen program.
    _ = try p.step("\x1b[3J");
    try std.testing.expectEqual(@as(usize, 0), p.client.screen.history.count);
    _ = try p.step("\x1b[?1049h\x1b[2;2Hfull");
    _ = try p.step("\x1b[?1049l");
    // A resize starts over.
    try p.server.screen.resize(12, 4);
    try p.client.screen.resize(12, 4);
    _ = try p.step("");
    // Many lines at once, more than the screen.
    _ = try p.step("\r\na\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng");
    // A user's clear on the server.
    _ = p.server.clearScreen();
    _ = try p.step("");
}

test "frames carry modes, colors, the title, the cursor and the clipboard" {
    var p: Pair = undefined;
    try p.init(10, 3);
    defer p.deinit();
    const frame = try p.step("\x1b[?1h\x1b[?2004h\x1b[?1002h\x1b[?1006h\x1b]11;#102030\x1b\\\x1b]4;1;#ff0000\x1b\\\x1b]2;hello\x07\x1b[5 q\x1b[?25l\x1b]52;c;aGk=\x07\x1b]52;c;?\x07");
    const c = &p.client;
    try std.testing.expect(c.screen.modes.cursor_keys and c.screen.modes.bracketed_paste);
    try std.testing.expectEqual(screen_module.MouseTracking.button, c.screen.modes.mouse);
    try std.testing.expectEqual(screen_module.MouseEncoding.sgr, c.screen.modes.mouse_encoding);
    try std.testing.expectEqual(@as(u24, 0x102030), c.background);
    try std.testing.expectEqual(@as(u24, 0xff0000), c.palette[1]);
    try std.testing.expectEqualStrings("hello", c.title());
    try std.testing.expectEqual(screen_module.CursorShape.bar, c.screen.modes.cursor_shape);
    try std.testing.expect(!c.screen.modes.cursor_visible);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b]52;c;aGk=\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b]52;c;?\x1b\\") != null);
    // Once only.
    try std.testing.expectEqualStrings("", try p.step(""));
    // Reset, they go back to the other terminal's own.
    _ = try p.step("\x1b[?1002l\x1b]111\x1b\\\x1b]104\x1b\\\x1b[0 q");
    try std.testing.expectEqual(screen_module.MouseTracking.none, c.screen.modes.mouse);
    try std.testing.expect(!c.background_set);
    try std.testing.expect(!c.palette_set.isSet(1));
    try std.testing.expectEqual(screen_module.CursorShape.block, c.screen.modes.cursor_shape);
    // A synchronized update holds frames back, up to a second.
    p.server.feed("\x1b[?2026hx");
    p.out.clearRetainingCapacity();
    try std.testing.expect(try p.mirror.frame(&p.out, 100));
    try std.testing.expect(try p.mirror.frame(&p.out, 900));
    try std.testing.expect(!try p.mirror.frame(&p.out, 1100));
    try std.testing.expect(p.out.items.len > 0);
}

test "frames send images, place them and delete them" {
    var p: Pair = undefined;
    try p.init(10, 3);
    defer p.deinit();
    p.server.cell_width = 8;
    p.server.cell_height = 16;
    p.client.cell_width = 8;
    p.client.cell_height = 16;
    _ = try p.step("\x1b[2;3H\x1b_Ga=T,f=24,s=1,v=1,i=4,c=2,r=1,q=2;AAAA\x1b\\");
    const placed = p.client.images[0].placements.items;
    try std.testing.expectEqual(@as(usize, 1), placed.len);
    try std.testing.expectEqual(p.server.images[0].placements.items[0].row, placed[0].row);
    try std.testing.expectEqual(@as(u16, 2), placed[0].col);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, p.client.images[0].image(4).?.pixels);
    // Unchanged: nothing sent again.
    try std.testing.expectEqualStrings("", try p.step(""));
    _ = try p.step("\x1b_Ga=d,d=I,i=4,q=2\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), p.client.images[0].images.items.len);
}

test "a snapshot shows the same in a new terminal, and history stops at the cursor" {
    var server = try Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 3, .scrollback = 50 } });
    defer server.deinit();
    server.feed("a\r\n\x1b[1mb\x1b[0m\r\nc\r\nd\r\ne\x1b[?7l\x1b(0");
    const bytes = try snapshot(std.testing.allocator, &server);
    defer std.testing.allocator.free(bytes);
    var copy = try Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 3, .scrollback = 50 } });
    defer copy.deinit();
    copy.feed(bytes);
    try expectSame(&server, &copy);
    try std.testing.expect(!copy.screen.modes.autowrap);
    try std.testing.expectEqual(screen_module.Charset.dec_graphics, copy.screen.cursor.charsets[0]);
    // On the alternate screen the main one comes too.
    server.feed("\x1b[?1049hfull");
    const alt = try snapshot(std.testing.allocator, &server);
    defer std.testing.allocator.free(alt);
    var alt_copy = try Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 3, .scrollback = 50 } });
    defer alt_copy.deinit();
    alt_copy.feed(alt);
    try expectSame(&server, &alt_copy);
    alt_copy.feed("\x1b[?1049l");
    server.feed("\x1b[?1049l");
    try expectSame(&server, &alt_copy);

    const whole = (try history(std.testing.allocator, &server)).?;
    std.testing.allocator.free(whole);
    server.feed("\x1b[?1049h");
    try std.testing.expect(try history(std.testing.allocator, &server) == null);
    server.feed("\x1b[?1049l\x1b[2;1H");
    const past = (try history(std.testing.allocator, &server)).?;
    defer std.testing.allocator.free(past);
    var next = try Terminal.init(std.testing.allocator, .{ .screen = .{ .cols = 10, .rows = 3, .scrollback = 50 } });
    defer next.deinit();
    next.feed(past);
    var buffer: [64]u8 = undefined;
    // Down to the cursor's row, which held "d": the cursor under it.
    try std.testing.expectEqualStrings("d", rowText(&next, next.screen.screenRow(next.screen.cursor.y - 1), &buffer));
    try std.testing.expectEqual(@as(u16, 0), next.screen.cursor.x);
}
