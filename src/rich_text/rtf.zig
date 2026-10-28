//! Attributed text from Rich Text Format, as desktop word processors copy
//! it: paragraphs, their alignment and lists, bold, italic, underline,
//! strikethrough and links. Fonts, sizes and colors are left out, as the
//! HTML reader leaves them.
const std = @import("std");
const tx = @import("text.zig");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;
const Text = tx.Text;
const Attributes = tx.Attributes;

pub fn parse(allocator: Allocator, data: []const u8) !Text {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Reader = .{ .arena = arena, .s = std.mem.trimEnd(u8, data, "\x00") };
    try r.read();
    try r.endParagraph(false);
    var paras = r.paras.items;
    while (paras.len > 1 and paras[paras.len - 1].runs.len == 0) paras = paras[0 .. paras.len - 1];
    if (paras.len == 0) return Text.init(allocator);
    return Text.of(allocator, paras);
}

const Field = enum { none, inst, result };

/// What a group sets: the formats of characters, the style of the
/// paragraph, and what the group holds.
const State = struct {
    a: Attributes = .{},
    @"align": tx.Align = .start,
    /// A destination whose text is not the document's.
    skip: bool = false,
    field: Field = .none,
    /// The URL of the field the group is in.
    link: []const u8 = "",
    /// A paragraph's list text, which says its marker.
    list: bool = false,
    /// Hidden text.
    hide: bool = false,
    /// Characters that follow a \u as its fallback.
    uc: u32 = 1,
};

const Reader = struct {
    arena: Allocator,
    s: []const u8,
    i: usize = 0,
    state: State = .{},
    stack: std.ArrayList(State) = .empty,
    paras: std.ArrayList(tx.Paragraph) = .empty,
    runs: std.ArrayList(tx.Run) = .empty,
    style: tx.ParagraphStyle = .{},
    text: std.ArrayList(u8) = .empty,
    run_a: Attributes = .{},
    inst: std.ArrayList(u8) = .empty,
    marker: std.ArrayList(u8) = .empty,
    listed: bool = false,
    level: u8 = 0,

    fn flush(self: *Reader) !void {
        if (self.text.items.len > 0) {
            try self.runs.append(self.arena, .{ .text = try self.text.toOwnedSlice(self.arena), .attributes = self.run_a });
        }
    }

    fn emit(self: *Reader, s: []const u8) !void {
        const st = &self.state;
        if (st.list) return self.marker.appendSlice(self.arena, s);
        if (st.field == .inst) return self.inst.appendSlice(self.arena, s);
        if (st.skip or st.hide) return;
        var a = st.a;
        if (st.field == .result and st.link.len > 0) a.link = st.link;
        if (!a.eql(self.run_a)) {
            try self.flush();
            self.run_a = a;
        }
        try self.text.appendSlice(self.arena, s);
    }

    fn emitRune(self: *Reader, rune: u21) !void {
        var buffer: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(rune, &buffer) catch return;
        try self.emit(buffer[0..n]);
    }

    fn endParagraph(self: *Reader, always: bool) !void {
        try self.flush();
        if (!always and self.runs.items.len == 0 and !self.listed) return;
        var style: tx.ParagraphStyle = .{ .@"align" = self.state.@"align" };
        if (self.listed) {
            const m = std.mem.trim(u8, self.marker.items, " \t");
            style.list = .bullets;
            if (m.len > 0 and (std.ascii.isDigit(m[0]) or (m.len > 1 and m[m.len - 1] == '.'))) style.list = .numbers;
            style.indent = self.level;
        }
        try self.paras.append(self.arena, .{ .style = style, .runs = try self.runs.toOwnedSlice(self.arena) });
        self.marker.clearRetainingCapacity();
        self.listed = false;
        self.level = 0;
    }

    fn read(self: *Reader) !void {
        const s = self.s;
        // After \*: the group is a destination to skip.
        var pending_skip = false;
        while (self.i < s.len) {
            const c = s[self.i];
            switch (c) {
                '{' => {
                    try self.stack.append(self.arena, self.state);
                    self.i += 1;
                },
                '}' => {
                    const was_inst = self.state.field == .inst;
                    if (self.stack.pop()) |previous| self.state = previous;
                    if (was_inst and self.state.field != .inst) {
                        // The field's group: its result links to the URL of
                        // its instruction.
                        self.state.link = html.safeLink(try hyperlink(self.arena, self.inst.items));
                        self.inst.clearRetainingCapacity();
                    }
                    self.i += 1;
                },
                '\\' => {
                    self.i += 1;
                    if (self.i >= s.len) return;
                    const d = s[self.i];
                    if (d == '\'' and self.i + 2 < s.len) {
                        // A character of the code page, as Windows-1252.
                        if (std.fmt.parseInt(u8, s[self.i + 1 .. self.i + 3], 16)) |v| try self.emitRune(cp1252(v)) else |_| {}
                        self.i += 3;
                    } else if (d == '*') {
                        pending_skip = true;
                        self.i += 1;
                    } else if (d == '\\' or d == '{' or d == '}') {
                        try self.emit(s[self.i .. self.i + 1]);
                        self.i += 1;
                    } else if (d == '~') {
                        try self.emitRune(0xa0);
                        self.i += 1;
                    } else if (d == '_') {
                        // A hyphen lines don't break at.
                        try self.emitRune(0x2011);
                        self.i += 1;
                    } else if (d == '\n' or d == '\r') {
                        // A backslash and a newline is a \par.
                        try self.endParagraph(true);
                        self.i += 1;
                    } else if (std.ascii.isAlphabetic(d)) {
                        const w = self.word();
                        if (pending_skip) {
                            pending_skip = false;
                            if (!std.mem.eql(u8, w.word, "fldinst")) self.state.skip = true;
                        }
                        try self.control(w.word, w.num, w.has_num);
                    } else self.i += 1;
                },
                '\r', '\n' => self.i += 1,
                else => {
                    var j = self.i;
                    while (j < s.len and s[j] != '\\' and s[j] != '{' and s[j] != '}' and s[j] != '\r' and s[j] != '\n') j += 1;
                    try self.emitLatin(s[self.i..j]);
                    self.i = j;
                },
            }
        }
    }

    /// Emits text, as UTF-8 when it is and as Windows-1252 otherwise.
    fn emitLatin(self: *Reader, bytes: []const u8) !void {
        if (std.unicode.utf8ValidateSlice(bytes)) return self.emit(bytes);
        for (bytes) |b| try self.emitRune(cp1252(b));
    }

    const Word = struct { word: []const u8, num: i32, has_num: bool };

    /// Reads a control word, its number and the space ending them.
    fn word(self: *Reader) Word {
        const s = self.s;
        const start = self.i;
        while (self.i < s.len and std.ascii.isAlphabetic(s[self.i])) self.i += 1;
        const w = s[start..self.i];
        const num_start = self.i;
        if (self.i < s.len and s[self.i] == '-') self.i += 1;
        while (self.i < s.len and std.ascii.isDigit(s[self.i])) self.i += 1;
        const num = std.fmt.parseInt(i32, s[num_start..self.i], 10) catch null;
        if (self.i < s.len and s[self.i] == ' ') self.i += 1;
        return .{ .word = w, .num = num orelse 0, .has_num = num != null };
    }

    fn control(self: *Reader, w: []const u8, num: i32, has_num: bool) !void {
        const st = &self.state;
        const on = !has_num or num != 0;
        const skipped = [_][]const u8{ "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer", "footnote", "listtable", "listoverridetable", "expandedcolortbl", "themedata", "colorschememapping", "latentstyles", "datastore", "xmlnstbl", "rsidtbl", "generator", "object", "shppict", "nonshppict" };
        for (skipped) |name| if (std.mem.eql(u8, w, name)) {
            st.skip = true;
            return;
        };
        const eq = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.mem.eql(u8, a, b);
            }
        }.f;
        if (eq(w, "field")) {
            st.field = .none;
            st.link = "";
        } else if (eq(w, "fldinst")) {
            st.field = .inst;
            st.skip = false;
        } else if (eq(w, "fldrslt")) {
            st.field = .result;
        } else if (eq(w, "listtext") or eq(w, "pntext")) {
            // The marker of a list's item.
            st.list = true;
            self.listed = true;
        } else if (eq(w, "ls")) {
            self.listed = true;
        } else if (eq(w, "ilvl")) {
            self.level = @intCast(std.math.clamp(num, 0, tx.max_indent));
        } else if (eq(w, "par") or eq(w, "line") or eq(w, "sect") or eq(w, "page") or eq(w, "row")) {
            if (!st.skip and !st.list and st.field != .inst) try self.endParagraph(true);
        } else if (eq(w, "pard")) {
            st.@"align" = .start;
        } else if (eq(w, "ql") or eq(w, "qj")) {
            st.@"align" = .start;
        } else if (eq(w, "qc")) {
            st.@"align" = .center;
        } else if (eq(w, "qr")) {
            st.@"align" = .end;
        } else if (eq(w, "plain")) {
            st.a = .{};
            st.hide = false;
        } else if (eq(w, "b")) {
            st.a.weight = if (on) 700 else 0;
        } else if (eq(w, "i")) {
            st.a.italic = on;
        } else if (eq(w, "ul") or eq(w, "uld") or eq(w, "uldb") or eq(w, "ulw") or eq(w, "ulth")) {
            st.a.underline = on;
        } else if (eq(w, "ulnone")) {
            st.a.underline = false;
        } else if (eq(w, "strike") or eq(w, "striked")) {
            st.a.strikethrough = on;
        } else if (eq(w, "tab") or eq(w, "cell")) {
            try self.emit("\t");
        } else if (eq(w, "v")) {
            st.hide = on;
        } else if (eq(w, "emdash")) {
            try self.emit("—");
        } else if (eq(w, "endash")) {
            try self.emit("–");
        } else if (eq(w, "bullet")) {
            try self.emit("•");
        } else if (eq(w, "lquote")) {
            try self.emit("‘");
        } else if (eq(w, "rquote")) {
            try self.emit("’");
        } else if (eq(w, "ldblquote")) {
            try self.emit("“");
        } else if (eq(w, "rdblquote")) {
            try self.emit("”");
        } else if (eq(w, "uc")) {
            st.uc = @intCast(@max(num, 0));
        } else if (eq(w, "u")) {
            var v: i32 = num;
            if (v < 0) v += 65536;
            var rune: u32 = @intCast(@max(v, 0));
            // A surrogate pair comes as two \u.
            if (rune >= 0xd800 and rune <= 0xdbff) {
                self.skipFallback();
                if (std.mem.startsWith(u8, self.s[self.i..], "\\u")) {
                    self.i += 1;
                    var low = self.word().num;
                    if (low < 0) low += 65536;
                    rune = 0x10000 + ((rune - 0xd800) << 10) + (@as(u32, @intCast(@max(low, 0xdc00))) - 0xdc00);
                }
            }
            if (rune <= 0x10ffff and !(rune >= 0xd800 and rune <= 0xdfff)) try self.emitRune(@intCast(rune));
            self.skipFallback();
        }
    }

    /// Skips the characters after a \u that stand for it where Unicode is
    /// not read.
    fn skipFallback(self: *Reader) void {
        var n = self.state.uc;
        while (n > 0 and self.i < self.s.len) : (n -= 1) {
            const c = self.s[self.i];
            if (c == '\\' and self.i + 3 < self.s.len and self.s[self.i + 1] == '\'') {
                self.i += 4;
            } else if (c == '\\' or c == '{' or c == '}') {
                return;
            } else self.i += 1;
        }
    }
};

/// The URL of a field's instruction, HYPERLINK "url".
fn hyperlink(arena: Allocator, raw: []const u8) ![]const u8 {
    const inst = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, inst, "HYPERLINK")) return "";
    const rest = std.mem.trim(u8, inst["HYPERLINK".len..], " \t\r\n");
    // \l "name" links to a bookmark of the document.
    if (std.mem.startsWith(u8, rest, "\\l")) {
        const inner = try std.fmt.allocPrint(arena, "HYPERLINK {s}", .{std.mem.trim(u8, rest[2..], " \t")});
        const u = try hyperlink(arena, inner);
        if (u.len == 0) return "";
        return std.fmt.allocPrint(arena, "#{s}", .{u});
    }
    if (rest.len > 0 and rest[0] == '"') {
        if (std.mem.indexOfScalarPos(u8, rest, 1, '"')) |end| return rest[1..end];
    }
    var it = std.mem.tokenizeAny(u8, rest, " \t\r\n");
    return it.next() orelse "";
}

/// The rune of a byte of Windows-1252.
fn cp1252(b: u8) u21 {
    const high = [32]u21{ 0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, 0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f, 0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178 };
    if (b >= 0x80 and b < 0xa0) return high[b - 0x80];
    return b;
}
