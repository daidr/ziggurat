//! Attributed text: runs of text with attributes of their own, in
//! paragraphs that have a style of their own, as a rich text editor edits
//! it. Offsets count Unicode scalars (runes), newlines included.
//! Paragraphs end at newlines; the style of a paragraph and the attributes
//! of its newline belong to it, as in word processors, so that an empty
//! paragraph remembers the attributes typing gets there. Runs are kept as
//! long as they can be: neighbors with the same attributes are one run.
//!
//! A Text owns its paragraphs, the strings its attributes name and the
//! attachments it holds. Attributes read from it borrow its storage until
//! it is changed or released. All methods run on one thread at a time.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// A color of text or of a highlight; alpha 0 leaves it unset.
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub fn rgb(hex: u32) Color {
        return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex), .a = 255 };
    }
    pub fn set(self: Color) bool {
        return self.a != 0;
    }
    /// 0xRRGGBB, without alpha.
    pub fn value(self: Color) u32 {
        return (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | self.b;
    }
    pub fn withAlpha(self: Color, alpha: f32) Color {
        var out = self;
        out.a = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 255));
        return out;
    }
};

/// The character an Attachment takes in a text.
pub const object_replacement: u21 = 0xfffc;
pub const object_replacement_utf8 = "\u{fffc}";

/// An object inside a Text, as an image in a note: one object replacement
/// character (U+FFFC) whose attributes hold it, laid out as a box of its
/// size inside the line, on the baseline, and selected, copied and deleted
/// as one character.
pub const Attachment = struct {
    /// Size of the box in DIP; zero takes the image's size.
    width: f32 = 0,
    height: f32 = 0,
    /// Describes the attachment to assistive technology and stands for it
    /// in plain text: an image's alternative text, a file's name.
    name: []const u8 = "",
    /// Where the attachment comes from, which HTML and Markdown write.
    url: []const u8 = "",
    /// Encoded image bytes the attachment carries, as a pasted picture
    /// brings in a data URL.
    image: []const u8 = "",
    /// Pixel size of `image`, read from its header; 0 when unknown.
    image_width: f32 = 0,
    image_height: f32 = 0,
    /// The application's, for the editor's attachment painter.
    data: ?*anyopaque = null,

    /// The size of the box: its own, or its image's scaled to fit.
    pub fn size(self: *const Attachment) struct { width: f32, height: f32 } {
        var w = self.width;
        var h = self.height;
        const iw = self.image_width;
        const ih = self.image_height;
        if (w <= 0 and h <= 0) {
            w = iw;
            h = ih;
        } else if (w <= 0 and ih > 0) {
            w = h * iw / ih;
        } else if (h <= 0 and iw > 0) {
            h = w * ih / iw;
        }
        return .{ .width = @max(w, 1), .height = @max(h, 1) };
    }
};

/// The attributes of a run. What they leave zero takes the style of the
/// editor showing the text (its font, size and color); italic, underline,
/// strikethrough and code only turn those on.
pub const Attributes = struct {
    /// A font family name; "" for the editor's.
    font: []const u8 = "",
    /// Size in DIP; 0 for the editor's.
    size: f32 = 0,
    /// From 100 (thin) to 900 (black): 700 is bold; 0 for regular.
    weight: u16 = 0,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    /// Colors the text; Background highlights it.
    color: Color = .{},
    background: Color = .{},
    /// Inline code in the editor's monospaced font. Typing at its edges
    /// does not continue it.
    code: bool = false,
    /// A URL the run links to. Typing at its edges does not continue it.
    link: []const u8 = "",
    /// The application's own mark over the run, as a mention or a
    /// comment's id: typing at its edges does not continue it.
    tag: []const u8 = "",
    /// What an object replacement character shows. Only that character
    /// takes it.
    attachment: ?*const Attachment = null,

    /// Bold: a weight of 600 or more.
    pub fn bold(self: Attributes) bool {
        return self.weight >= 600;
    }
    /// The attributes typing right after a run continues: links, code,
    /// tags and attachments hold only what they hold.
    pub fn extending(self: Attributes) Attributes {
        var out = self;
        out.link = "";
        out.code = false;
        out.tag = "";
        out.attachment = null;
        return out;
    }
    pub fn eql(a: Attributes, b: Attributes) bool {
        return std.mem.eql(u8, a.font, b.font) and a.size == b.size and a.weight == b.weight and a.italic == b.italic and
            a.underline == b.underline and a.strikethrough == b.strikethrough and std.meta.eql(a.color, b.color) and
            std.meta.eql(a.background, b.background) and a.code == b.code and std.mem.eql(u8, a.link, b.link) and
            std.mem.eql(u8, a.tag, b.tag) and a.attachment == b.attachment;
    }
};

/// What a paragraph is an item of.
pub const ListKind = enum(u8) {
    none,
    /// An unordered list.
    bullets,
    /// An ordered list, numbered from 1 among the items of one level next
    /// to each other.
    numbers,
    /// A checklist, whose items are checked or not.
    tasks,
};

pub const Align = enum(u8) { start, center, end };

/// The deepest a paragraph indents.
pub const max_indent = 8;

/// The style of a paragraph: what it is (a heading, an item of a list, a
/// quotation, a block of code) and how its lines align. Lists are flat:
/// an item's indent is its level, and items next to each other make a
/// list.
pub const ParagraphStyle = struct {
    /// Level of a heading, from 1, or 0 for a body paragraph.
    heading: u8 = 0,
    list: ListKind = .none,
    /// A task done.
    checked: bool = false,
    /// Levels the paragraph is indented: the level of a list's item.
    indent: u8 = 0,
    @"align": Align = .start,
    quote: bool = false,
    code_block: bool = false,
    /// The application's name for the paragraph, the key of what it keeps
    /// about it, which the editor does not show. It stays with the
    /// paragraph's text as it is edited (see `Text.replace`): a paragraph
    /// split keeps it in its first half (the second when split at its
    /// start), paragraphs joined keep the first's, and the paragraphs an
    /// edit makes have none, unless the document names them
    /// (`Document.identifyParagraphs`). Undo brings it back with the text,
    /// saved JSON keeps it, and the clipboard, Markdown, HTML and RTF leave
    /// it out. Interned in the paragraph's text.
    id: []const u8 = "",

    /// The style with its levels in range.
    pub fn normalized(self: ParagraphStyle) ParagraphStyle {
        var s = self;
        s.heading = @min(s.heading, 6);
        s.indent = @min(s.indent, max_indent);
        if (s.list != .tasks) s.checked = false;
        return s;
    }
    pub fn eql(a: ParagraphStyle, b: ParagraphStyle) bool {
        return a.looksLike(b) and std.mem.eql(u8, a.id, b.id);
    }
    /// Whether the styles look the same, whatever their IDs.
    pub fn looksLike(a: ParagraphStyle, b: ParagraphStyle) bool {
        var x = a;
        x.id = b.id;
        return std.meta.eql(x, b);
    }
    /// The style without its ID.
    pub fn anonymous(self: ParagraphStyle) ParagraphStyle {
        var s = self;
        s.id = "";
        return s;
    }
};

/// A run of text with its attributes.
pub const Run = struct {
    text: []const u8,
    attributes: Attributes = .{},
};

/// A paragraph to build a Text of: its style and its runs, without its
/// newline. A newline in a run starts another paragraph of the same style,
/// without its ID.
pub const Paragraph = struct {
    style: ParagraphStyle = .{},
    runs: []const Run = &.{},
};

pub const AttrRun = struct {
    n: u32,
    a: Attributes,
};

/// A paragraph of a Text. Its runs hold its runes and, last, its end: its
/// newline, or for the last paragraph the end of the text, whose
/// attributes are those typing gets in an empty paragraph. They are as
/// long as they can be, none empty: n+1 runes in all.
pub const Para = struct {
    /// Stays with the paragraph as the text changes around it.
    id: u64,
    /// Changes whenever the paragraph's text, runs or style change.
    revision: u64,
    style: ParagraphStyle,
    bytes: std.ArrayList(u8) = .empty,
    /// Runes, without the end.
    n: u32 = 0,
    runs: std.ArrayList(AttrRun) = .empty,

    pub fn deinit(self: *Para, allocator: Allocator) void {
        self.bytes.deinit(allocator);
        self.runs.deinit(allocator);
        self.* = undefined;
    }
    pub fn clone(self: *const Para, allocator: Allocator) !Para {
        var out = self.*;
        out.bytes = try self.bytes.clone(allocator);
        errdefer out.bytes.deinit(allocator);
        out.runs = try self.runs.clone(allocator);
        return out;
    }
    pub fn text(self: *const Para) []const u8 {
        return self.bytes.items;
    }
    /// The attributes of rune i of the paragraph, its end for n.
    pub fn attributesAt(self: *const Para, i: u32) Attributes {
        var at: u32 = 0;
        for (self.runs.items) |r| {
            at += r.n;
            if (i < at) return r.a;
        }
        return self.runs.items[self.runs.items.len - 1].a;
    }
    /// The attributes of the paragraph's end.
    pub fn endAttributes(self: *const Para) Attributes {
        return self.runs.items[self.runs.items.len - 1].a;
    }
    /// Byte offset of rune i within the paragraph's text.
    pub fn byteOf(self: *const Para, i: u32) usize {
        return byteOfRune(self.bytes.items, i);
    }
    /// The runs of the paragraph's text, without its end.
    pub fn iterator(self: *const Para) RunIterator {
        return .{ .para = self };
    }
};

/// The runs of one paragraph's text, without its end.
pub const RunIterator = struct {
    para: *const Para,
    index: usize = 0,
    byte: usize = 0,
    rune: u32 = 0,

    pub const Item = struct { start: u32, run: Run };

    pub fn next(self: *RunIterator) ?Item {
        const p = self.para;
        while (self.index < p.runs.items.len) {
            const r = p.runs.items[self.index];
            self.index += 1;
            const take = @min(r.n, p.n - self.rune);
            if (take == 0) return null;
            const start = self.byte;
            const end = start + byteOfRune(p.bytes.items[start..], take);
            const item: Item = .{ .start = self.rune, .run = .{ .text = p.bytes.items[start..end], .attributes = r.a } };
            self.byte = end;
            self.rune += take;
            return item;
        }
        return null;
    }
};

/// Byte offset of rune i of UTF-8 text, or its length past its end.
pub fn byteOfRune(bytes: []const u8, i: usize) usize {
    var at: usize = 0;
    var count: usize = 0;
    while (at < bytes.len and count < i) : (count += 1) at += std.unicode.utf8ByteSequenceLength(bytes[at]) catch 1;
    return @min(at, bytes.len);
}

pub fn runeCount(bytes: []const u8) u32 {
    var n: u32 = 0;
    for (bytes) |b| {
        if (b & 0xc0 != 0x80) n += 1;
    }
    return n;
}

/// Decodes the rune at byte `at`, and its length.
pub fn decodeAt(bytes: []const u8, at: usize) struct { rune: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return .{ .rune = 0xfffd, .len = 1 };
    if (at + len > bytes.len) return .{ .rune = 0xfffd, .len = 1 };
    const rune = std.unicode.utf8Decode(bytes[at..][0..len]) catch return .{ .rune = 0xfffd, .len = 1 };
    return .{ .rune = rune, .len = len };
}

/// The strings and attachments a text's attributes name, owned by it.
const Pool = struct {
    strings: std.StringHashMapUnmanaged(void) = .empty,
    attachments: std.ArrayList(*Attachment) = .empty,

    fn deinit(self: *Pool, allocator: Allocator) void {
        var it = self.strings.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        self.strings.deinit(allocator);
        for (self.attachments.items) |a| allocator.destroy(a);
        self.attachments.deinit(allocator);
    }
    fn intern(self: *Pool, allocator: Allocator, s: []const u8) ![]const u8 {
        if (s.len == 0) return "";
        if (self.strings.getKey(s)) |key| return key;
        const owned = try allocator.dupe(u8, s);
        errdefer allocator.free(owned);
        try self.strings.put(allocator, owned, {});
        return owned;
    }
    fn owns(self: *const Pool, a: *const Attachment) bool {
        for (self.attachments.items) |item| if (item == a) return true;
        return false;
    }
    fn internAttachment(self: *Pool, allocator: Allocator, a: *const Attachment) !*const Attachment {
        if (self.owns(a)) return a;
        var copy = a.*;
        copy.name = try self.intern(allocator, a.name);
        copy.url = try self.intern(allocator, a.url);
        copy.image = try self.intern(allocator, a.image);
        const out = try allocator.create(Attachment);
        errdefer allocator.destroy(out);
        out.* = copy;
        try self.attachments.append(allocator, out);
        return out;
    }
    fn internAttributes(self: *Pool, allocator: Allocator, a: Attributes) !Attributes {
        var out = a;
        out.font = try self.intern(allocator, a.font);
        out.link = try self.intern(allocator, a.link);
        out.tag = try self.intern(allocator, a.tag);
        if (a.attachment) |at| out.attachment = try self.internAttachment(allocator, at);
        return out;
    }
};

/// appendRun appends r, joined to the last run when they have the same
/// attributes; runs holding an attachment are never joined.
fn appendRun(allocator: Allocator, runs: *std.ArrayList(AttrRun), r: AttrRun) !void {
    if (r.n == 0) return;
    if (runs.items.len > 0) {
        const last = &runs.items[runs.items.len - 1];
        if (last.a.eql(r.a) and r.a.attachment == null) {
            last.n += r.n;
            return;
        }
    }
    try runs.append(allocator, r);
}

/// Appends the runs from rune `from` up to rune `to` of `runs`.
fn cutRuns(allocator: Allocator, dst: *std.ArrayList(AttrRun), runs: []const AttrRun, from: u32, to: u32) !void {
    var at: u32 = 0;
    for (runs) |r| {
        const a = @max(at, from);
        const z = @min(at + r.n, to);
        if (a < z) try appendRun(allocator, dst, .{ .n = z - a, .a = r.a });
        at += r.n;
        if (at >= to) break;
    }
}

/// Appends the runs of `s` in attributes `a`: an object replacement
/// character is a run of its own where `a` holds an attachment, which no
/// other rune takes.
fn appendTextRuns(allocator: Allocator, runs: *std.ArrayList(AttrRun), s: []const u8, a: Attributes) !void {
    if (s.len == 0) return;
    if (a.attachment == null) return appendRun(allocator, runs, .{ .n = runeCount(s), .a = a });
    var plain = a;
    plain.attachment = null;
    var at: usize = 0;
    while (at < s.len) {
        const d = decodeAt(s, at);
        at += d.len;
        try appendRun(allocator, runs, .{ .n = 1, .a = if (d.rune == object_replacement) a else plain });
    }
}

pub const Text = struct {
    allocator: Allocator,
    /// Never empty: the empty text has one empty paragraph.
    paras: std.ArrayList(Para) = .empty,
    pool: Pool = .{},
    next_id: u64 = 1,
    next_revision: u64 = 1,
    /// Rune each paragraph starts at, while `starts_valid`. Rebuilt
    /// whenever the paragraphs change, never by the readers: they take the
    /// text as const, and writing through that pointer is undefined.
    starts: std.ArrayList(u32) = .empty,
    starts_valid: bool = false,
    total: u32 = 0,

    /// The empty text.
    pub fn init(allocator: Allocator) !Text {
        var t: Text = .{ .allocator = allocator };
        errdefer t.deinit();
        try t.paras.append(allocator, t.newPara(.{}));
        try t.paras.items[0].runs.append(allocator, .{ .n = 1, .a = .{} });
        t.index();
        return t;
    }

    /// `s` without attributes.
    pub fn initString(allocator: Allocator, s: []const u8) !Text {
        return of(allocator, &.{.{ .runs = &.{.{ .text = s }} }});
    }

    /// A text of paragraphs; a newline in a run starts another paragraph
    /// of the same style, without its ID.
    pub fn of(allocator: Allocator, paragraphs: []const Paragraph) !Text {
        var t: Text = .{ .allocator = allocator };
        errdefer t.deinit();
        if (paragraphs.len == 0) {
            t.deinit();
            return init(allocator);
        }
        for (paragraphs) |p| {
            var cur = t.newPara(try t.internStyle(p.style));
            errdefer cur.deinit(allocator);
            var last: Attributes = .{};
            for (p.runs) |r| {
                const a = try t.pool.internAttributes(allocator, r.attributes);
                last = a;
                var rest = r.text;
                while (true) {
                    const nl = std.mem.indexOfScalar(u8, rest, '\n');
                    const part = if (nl) |k| rest[0..k] else rest;
                    try cur.bytes.appendSlice(allocator, part);
                    try appendTextRuns(allocator, &cur.runs, part, a);
                    if (nl == null) break;
                    try appendRun(allocator, &cur.runs, .{ .n = 1, .a = a.extending() });
                    cur.n = runeCount(cur.bytes.items);
                    try t.paras.append(allocator, cur);
                    cur = t.newPara(p.style.anonymous());
                    rest = rest[nl.? + 1 ..];
                }
            }
            try appendRun(allocator, &cur.runs, .{ .n = 1, .a = last.extending() });
            cur.n = runeCount(cur.bytes.items);
            try t.paras.append(allocator, cur);
        }
        t.index();
        return t;
    }

    pub fn deinit(self: *Text) void {
        for (self.paras.items) |*p| p.deinit(self.allocator);
        self.paras.deinit(self.allocator);
        self.pool.deinit(self.allocator);
        self.starts.deinit(self.allocator);
        self.* = undefined;
    }

    /// A copy of the text, its paragraphs' ids, styles and ends included.
    pub fn clone(self: *const Text, allocator: Allocator) !Text {
        var out: Text = .{ .allocator = allocator, .next_id = self.next_id, .next_revision = self.next_revision };
        errdefer out.deinit();
        try out.paras.ensureTotalCapacity(allocator, self.paras.items.len);
        for (self.paras.items) |*q| {
            var np: Para = .{ .id = q.id, .revision = q.revision, .style = try out.internStyle(q.style), .n = q.n };
            errdefer np.deinit(allocator);
            try np.bytes.appendSlice(allocator, q.bytes.items);
            try np.runs.ensureTotalCapacity(allocator, q.runs.items.len);
            for (q.runs.items) |r| np.runs.appendAssumeCapacity(.{ .n = r.n, .a = try out.pool.internAttributes(allocator, r.a) });
            out.paras.appendAssumeCapacity(np);
        }
        out.index();
        return out;
    }

    /// `style` with its ID interned here.
    fn internStyle(self: *Text, style: ParagraphStyle) !ParagraphStyle {
        var s = style;
        if (s.id.len > 0) s.id = try self.pool.intern(self.allocator, s.id);
        return s;
    }

    fn newPara(self: *Text, style: ParagraphStyle) Para {
        const id = self.next_id;
        self.next_id += 1;
        return .{ .id = id, .revision = self.revise(), .style = style.normalized() };
    }
    fn revise(self: *Text) u64 {
        const r = self.next_revision;
        self.next_revision += 1;
        return r;
    }

    fn index(self: *Text) void {
        if (self.starts_valid) return;
        self.starts.clearRetainingCapacity();
        var at: u32 = 0;
        // Out of memory leaves the cache invalid and falls back to scans.
        self.starts.ensureTotalCapacity(self.allocator, self.paras.items.len) catch {
            self.total = self.scanTotal();
            return;
        };
        for (self.paras.items) |p| {
            self.starts.appendAssumeCapacity(at);
            at += p.n + 1;
        }
        self.total = at - 1;
        self.starts_valid = true;
    }
    fn scanTotal(self: *const Text) u32 {
        var at: u32 = 0;
        for (self.paras.items) |p| at += p.n + 1;
        return at - 1;
    }
    /// Notes that paragraphs changed.
    pub fn invalidate(self: *Text) void {
        self.starts_valid = false;
        self.index();
    }

    /// Runes of the text, newlines included.
    pub fn len(self: *const Text) u32 {
        return if (self.starts_valid) self.total else self.scanTotal();
    }

    /// One more than the newlines.
    pub fn paragraphCount(self: *const Text) u32 {
        return @intCast(self.paras.items.len);
    }

    pub fn para(self: *const Text, p: u32) *const Para {
        return &self.paras.items[p];
    }

    /// The paragraph holding rune i, whose newline is its.
    pub fn paraAt(self: *const Text, i: u32) u32 {
        if (self.starts_valid) {
            const starts = self.starts.items;
            // The last start at or before i.
            var lo: usize = 0;
            var hi: usize = starts.len;
            while (hi - lo > 1) {
                const mid = (lo + hi) / 2;
                if (starts[mid] <= i) lo = mid else hi = mid;
            }
            return @intCast(lo);
        }
        var at: u32 = 0;
        for (self.paras.items, 0..) |p, k| {
            if (i <= at + p.n or k + 1 == self.paras.items.len) return @intCast(k);
            at += p.n + 1;
        }
        return 0;
    }

    /// The rune paragraph p starts at.
    pub fn paraStart(self: *const Text, p: u32) u32 {
        if (self.starts_valid) return self.starts.items[@min(p, self.starts.items.len - 1)];
        var at: u32 = 0;
        for (self.paras.items[0..@min(p, self.paras.items.len)]) |q| at += q.n + 1;
        return at;
    }

    /// Where the paragraph holding rune i starts and ends, before its
    /// newline.
    pub fn paragraphRange(self: *const Text, i: u32) struct { start: u32, end: u32 } {
        const p = self.paraAt(@min(i, self.len()));
        const start = self.paraStart(p);
        return .{ .start = start, .end = start + self.paras.items[p].n };
    }

    /// The attributes of rune i, or those of the end of the text for its
    /// length.
    pub fn attributesAt(self: *const Text, i: u32) Attributes {
        const at = @min(i, self.len());
        const p = self.paraAt(at);
        return self.paras.items[p].attributesAt(at - self.paraStart(p));
    }

    pub fn paragraphStyleAt(self: *const Text, i: u32) ParagraphStyle {
        return self.paras.items[self.paraAt(@min(i, self.len()))].style;
    }

    /// Rune i, '\n' at a paragraph's end, 0 past the text.
    pub fn runeAt(self: *const Text, i: u32) u21 {
        if (i >= self.len()) return 0;
        const p = self.paraAt(i);
        const q = &self.paras.items[p];
        const local = i - self.paraStart(p);
        if (local >= q.n) return '\n';
        return decodeAt(q.bytes.items, q.byteOf(local)).rune;
    }

    /// Writes the text without attributes.
    pub fn writeString(self: *const Text, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.paras.items, 0..) |p, k| {
            if (k > 0) try writer.writeByte('\n');
            try writer.writeAll(p.bytes.items);
        }
    }

    /// The text without attributes, allocated.
    pub fn string(self: *const Text, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        self.writeString(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    /// The runes from start to end as plain text, allocated.
    pub fn sliceString(self: *const Text, allocator: Allocator, start: u32, end: u32) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        self.writeRange(&out.writer, start, end) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    pub fn writeRange(self: *const Text, writer: *std.Io.Writer, start: u32, end: u32) std.Io.Writer.Error!void {
        const n = self.len();
        const a = @min(start, n);
        const z = @min(end, n);
        if (a >= z) return;
        const pa = self.paraAt(a);
        const pz = self.paraAt(z);
        var p = pa;
        while (p <= pz) : (p += 1) {
            const q = &self.paras.items[p];
            const ps = self.paraStart(p);
            const from = if (p == pa) a - ps else 0;
            const to = if (p == pz) z - ps else q.n + 1;
            try writer.writeAll(q.bytes.items[q.byteOf(from)..q.byteOf(@min(to, q.n))]);
            if (to > q.n) try writer.writeByte('\n');
        }
    }

    /// The text as plain text, its attachments left out.
    pub fn plainText(self: *const Text, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        for (self.paras.items, 0..) |p, k| {
            if (k > 0) out.writer.writeByte('\n') catch return error.OutOfMemory;
            var rest: []const u8 = p.bytes.items;
            while (std.mem.indexOf(u8, rest, object_replacement_utf8)) |at| {
                out.writer.writeAll(rest[0..at]) catch return error.OutOfMemory;
                rest = rest[at + object_replacement_utf8.len ..];
            }
            out.writer.writeAll(rest) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice();
    }

    /// Whether the two hold the same text with the same attributes and
    /// paragraph styles.
    pub fn eql(self: *const Text, other: *const Text) bool {
        if (self.paras.items.len != other.paras.items.len) return false;
        for (self.paras.items, other.paras.items) |p, q| {
            if (!p.style.eql(q.style) or !std.mem.eql(u8, p.bytes.items, q.bytes.items) or p.runs.items.len != q.runs.items.len) return false;
            for (p.runs.items, q.runs.items) |r, s| {
                if (r.n != s.n) return false;
                // Attachments differ by identity across texts: compare what
                // they show.
                var ra = r.a;
                var sa = s.a;
                if (ra.attachment != null and sa.attachment != null) {
                    const x = ra.attachment.?;
                    const y = sa.attachment.?;
                    if (!std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.url, y.url) or x.width != y.width or x.height != y.height) return false;
                    ra.attachment = null;
                    sa.attachment = null;
                }
                if (!ra.eql(sa)) return false;
            }
        }
        return true;
    }

    /// The runes from start to end with their attributes and the styles of
    /// their paragraphs, as a text of its own.
    pub fn slice(self: *const Text, allocator: Allocator, start: u32, end: u32) !Text {
        const n = self.len();
        const a = @min(start, n);
        const z = @min(end, n);
        if (a >= z) return init(allocator);
        var out: Text = .{ .allocator = allocator };
        errdefer out.deinit();
        const pa = self.paraAt(a);
        const pz = self.paraAt(z);
        const sa = self.paraStart(pa);
        const sz = self.paraStart(pz);
        var p = pa;
        while (p <= pz) : (p += 1) {
            const q = &self.paras.items[p];
            const from = if (p == pa) a - sa else 0;
            const last = p == pz;
            const to = if (last) z - sz else q.n + 1;
            var np = out.newPara(try out.internStyle(q.style));
            np.id = q.id;
            errdefer np.deinit(allocator);
            var cut: std.ArrayList(AttrRun) = .empty;
            defer cut.deinit(allocator);
            try cutRuns(allocator, &cut, q.runs.items, from, to);
            if (last) try appendRun(allocator, &cut, .{ .n = 1, .a = q.endAttributes() });
            for (cut.items) |r| try appendRun(allocator, &np.runs, .{ .n = r.n, .a = try out.pool.internAttributes(allocator, r.a) });
            try np.bytes.appendSlice(allocator, q.bytes.items[q.byteOf(from)..q.byteOf(@min(to, q.n))]);
            np.n = runeCount(np.bytes.items);
            try out.paras.append(allocator, np);
        }
        out.next_id = @max(out.next_id, self.next_id);
        out.index();
        return out;
    }

    /// The paragraphs a selection from start to end formats: those it
    /// touches, but for the one after a selection ending at its start.
    pub fn paragraphSpan(self: *const Text, start: u32, end: u32) struct { first: u32, last: u32 } {
        const n = self.len();
        const a = @min(@min(start, end), n);
        const z = @min(@max(start, end), n);
        const pa = self.paraAt(a);
        var pz = self.paraAt(z);
        if (z > a and pz > pa and z == self.paraStart(pz)) pz -= 1;
        return .{ .first = pa, .last = pz };
    }

    /// The paragraphs a replacement of start to end touches.
    pub fn replaceSpan(self: *const Text, start: u32, end: u32) struct { first: u32, last: u32 } {
        const n = self.len();
        const a = @min(@min(start, end), n);
        const z = @min(@max(start, end), n);
        return .{ .first = self.paraAt(a), .last = self.paraAt(z) };
    }

    /// The paragraphs a format of start to end touches.
    pub fn formatSpan(self: *const Text, start: u32, end: u32) struct { first: u32, last: u32 } {
        const n = self.len();
        const a = @min(start, n);
        const z = @min(end, n);
        const pa = self.paraAt(a);
        var pz = self.paraAt(z);
        if (z == self.paraStart(pz) and pz > pa and z < n) pz -= 1;
        return .{ .first = pa, .last = pz };
    }

    /// Replaces the runes from start to end with `with`. Paragraphs joined
    /// or split take the style of the one their first rune comes from:
    /// deleting the newline after a heading keeps the heading, and text put
    /// at the start of a paragraph brings its own paragraph's style.
    ///
    /// The IDs of paragraphs follow their text instead, and never come
    /// from `with`, so that no two paragraphs get one ID: a paragraph split
    /// keeps its ID in the first half, or in the second when split at its
    /// start, as Enter there moves the paragraph down; the new paragraphs
    /// have none; and paragraphs joined keep the first's, unless nothing of
    /// it is left.
    pub fn replace(self: *Text, start: u32, end: u32, with: *const Text) !void {
        const allocator = self.allocator;
        const n = self.len();
        const a = @min(@min(start, end), n);
        const z = @min(@max(start, end), n);
        const pa = self.paraAt(a);
        const pz = self.paraAt(z);
        const sa = self.paraStart(pa);
        const sz = self.paraStart(pz);
        const first = &self.paras.items[pa];
        const last = &self.paras.items[pz];
        const head_n = a - sa;
        const tail_n = last.n - (z - sz);

        var head: std.ArrayList(AttrRun) = .empty;
        defer head.deinit(allocator);
        try cutRuns(allocator, &head, first.runs.items, 0, head_n);
        var tail: std.ArrayList(AttrRun) = .empty;
        defer tail.deinit(allocator);
        try cutRuns(allocator, &tail, last.runs.items, z - sz, last.n + 1);
        const head_bytes = first.bytes.items[0..first.byteOf(head_n)];
        const tail_bytes = last.bytes.items[last.byteOf(z - sz)..];

        var out: std.ArrayList(Para) = .empty;
        defer {
            for (out.items) |*p| p.deinit(allocator);
            out.deinit(allocator);
        }
        const frags = with.paras.items;
        if (frags.len == 1) {
            const f = &frags[0];
            var style = if (head_n > 0) first.style else if (f.n > 0) f.style else last.style;
            style.id = if (head_n > 0 or f.n > 0) first.style.id else last.style.id;
            var np = self.newPara(style);
            np.id = first.id;
            errdefer np.deinit(allocator);
            try self.appendCut(&np.runs, head.items, 0, head_n, null);
            try self.appendCut(&np.runs, f.runs.items, 0, f.n, with);
            try self.appendCut(&np.runs, tail.items, 0, tail_n + 1, null);
            try np.bytes.appendSlice(allocator, head_bytes);
            try np.bytes.appendSlice(allocator, f.bytes.items);
            try np.bytes.appendSlice(allocator, tail_bytes);
            np.n = head_n + f.n + tail_n;
            try out.append(allocator, np);
        } else {
            const f0 = &frags[0];
            // Split at its start, the paragraph's text goes to the last
            // part, with its ID.
            const moved = pa == pz and head_n == 0;
            var style = if (head_n > 0) first.style else f0.style;
            style.id = if (moved) "" else first.style.id;
            var np = self.newPara(style);
            np.id = first.id;
            {
                errdefer np.deinit(allocator);
                try self.appendCut(&np.runs, head.items, 0, head_n, null);
                try self.appendCut(&np.runs, f0.runs.items, 0, f0.n + 1, with);
                try np.bytes.appendSlice(allocator, head_bytes);
                try np.bytes.appendSlice(allocator, f0.bytes.items);
                np.n = head_n + f0.n;
                try out.append(allocator, np);
            }
            for (frags[1 .. frags.len - 1]) |*f| {
                var mid = self.newPara(f.style.anonymous());
                errdefer mid.deinit(allocator);
                try self.appendCut(&mid.runs, f.runs.items, 0, f.n + 1, with);
                try mid.bytes.appendSlice(allocator, f.bytes.items);
                mid.n = f.n;
                try out.append(allocator, mid);
            }
            const fl = &frags[frags.len - 1];
            var last_style = if (fl.n > 0) fl.style else last.style;
            last_style.id = if (pz != pa) last.style.id else if (moved) first.style.id else "";
            var lp = self.newPara(last_style);
            if (pz != pa) lp.id = last.id;
            errdefer lp.deinit(allocator);
            try self.appendCut(&lp.runs, fl.runs.items, 0, fl.n, with);
            try self.appendCut(&lp.runs, tail.items, 0, tail_n + 1, null);
            try lp.bytes.appendSlice(allocator, fl.bytes.items);
            try lp.bytes.appendSlice(allocator, tail_bytes);
            lp.n = fl.n + tail_n;
            try out.append(allocator, lp);
        }
        try self.spliceParas(pa, pz - pa + 1, out.items);
        out.clearRetainingCapacity();
    }

    /// Appends the runs from `from` to `to` of `runs`, interned here when
    /// they come from another text.
    fn appendCut(self: *Text, dst: *std.ArrayList(AttrRun), runs: []const AttrRun, from: u32, to: u32, source: ?*const Text) !void {
        const allocator = self.allocator;
        if (source == null or source.? == self) return cutRuns(allocator, dst, runs, from, to);
        var cut: std.ArrayList(AttrRun) = .empty;
        defer cut.deinit(allocator);
        try cutRuns(allocator, &cut, runs, from, to);
        for (cut.items) |r| try appendRun(allocator, dst, .{ .n = r.n, .a = try self.pool.internAttributes(allocator, r.a) });
    }

    /// Replaces `count` paragraphs from `at` with `with`, whose ownership
    /// passes to the text.
    pub fn spliceParas(self: *Text, at: u32, count: u32, with: []const Para) !void {
        const allocator = self.allocator;
        if (with.len > count) try self.paras.ensureUnusedCapacity(allocator, with.len - count);
        for (self.paras.items[at .. at + count]) |*p| p.deinit(allocator);
        self.paras.replaceRangeAssumeCapacity(at, count, with);
        self.invalidate();
    }

    /// Removes `count` paragraphs from `at`, passing them to `out`.
    pub fn takeParas(self: *Text, at: u32, count: u32, out: *std.ArrayList(Para)) !void {
        try out.appendSlice(self.allocator, self.paras.items[at .. at + count]);
        self.paras.replaceRangeAssumeCapacity(at, count, &.{});
        self.invalidate();
    }

    /// Inserts paragraphs, whose ownership passes to the text.
    pub fn insertParas(self: *Text, at: u32, with: []const Para) !void {
        try self.paras.insertSlice(self.allocator, at, with);
        self.invalidate();
    }

    /// Replaces the runes from start to end with `s`, which takes
    /// attributes `a` and, for the paragraphs it adds, the style of the
    /// paragraph holding start.
    pub fn replaceString(self: *Text, start: u32, end: u32, s: []const u8, a: Attributes) !void {
        var frag = try Text.of(self.allocator, &.{.{ .style = self.paragraphStyleAt(@min(start, end)), .runs = &.{.{ .text = s, .attributes = a }} }});
        defer frag.deinit();
        // The end of each paragraph takes the typing attributes, also of
        // an empty string's.
        for (frag.paras.items) |*p| {
            const end_a = try frag.pool.internAttributes(self.allocator, a.extending());
            p.runs.items[p.runs.items.len - 1].a = end_a;
            if (p.runs.items.len > 1 and p.runs.items[p.runs.items.len - 2].a.eql(end_a) and end_a.attachment == null) {
                p.runs.items[p.runs.items.len - 2].n += 1;
                _ = p.runs.pop();
            }
        }
        try self.replace(start, end, &frag);
    }

    pub fn insert(self: *Text, at: u32, with: *const Text) !void {
        try self.replace(at, at, with);
    }

    pub fn delete(self: *Text, start: u32, end: u32) !void {
        var empty = try Text.init(self.allocator);
        defer empty.deinit();
        try self.replace(start, end, &empty);
    }

    /// Appends `s` in attributes `a`.
    pub fn append(self: *Text, s: []const u8, a: Attributes) !void {
        const n = self.len();
        try self.replaceString(n, n, s, a);
    }

    /// Changes the attributes of the runes from start to end, newlines
    /// included, with `changer.change(*Attributes)`; it cannot add or take
    /// away an attachment. Returns whether anything changed.
    pub fn format(self: *Text, start: u32, end: u32, changer: anytype) !bool {
        const allocator = self.allocator;
        const n = self.len();
        const a = @min(start, n);
        const z = @min(end, n);
        if (a >= z) return false;
        const span = self.formatSpan(a, z);
        var at = self.paraStart(span.first);
        var changed = false;
        var p = span.first;
        while (p <= span.last) : (p += 1) {
            const q = &self.paras.items[p];
            const from = if (a > at) a - at else 0;
            var to = @min(z - at, q.n + 1);
            if (z == n and p == span.last) to = q.n + 1;
            var runs: std.ArrayList(AttrRun) = .empty;
            errdefer runs.deinit(allocator);
            try cutRuns(allocator, &runs, q.runs.items, 0, from);
            var mid: std.ArrayList(AttrRun) = .empty;
            defer mid.deinit(allocator);
            try cutRuns(allocator, &mid, q.runs.items, from, to);
            var para_changed = false;
            for (mid.items) |r| {
                var b = r.a;
                changer.change(&b);
                b.attachment = r.a.attachment;
                b = try self.pool.internAttributes(allocator, b);
                if (!b.eql(r.a)) para_changed = true;
                try appendRun(allocator, &runs, .{ .n = r.n, .a = b });
            }
            try cutRuns(allocator, &runs, q.runs.items, to, q.n + 1);
            if (para_changed) {
                q.runs.deinit(allocator);
                q.runs = runs;
                q.revision = self.revise();
                changed = true;
            } else runs.deinit(allocator);
            at += q.n + 1;
        }
        return changed;
    }

    /// Changes the styles of the paragraphs from the one holding start to
    /// the one holding end, but for a paragraph end only starts, with
    /// `changer.change(*ParagraphStyle)`; an ID it gives is interned. Returns
    /// whether any changed.
    pub fn formatParagraphs(self: *Text, start: u32, end: u32, changer: anytype) !bool {
        const span = self.paragraphSpan(start, end);
        var changed = false;
        var p = span.first;
        while (p <= span.last) : (p += 1) {
            const q = &self.paras.items[p];
            var s = q.style;
            changer.change(&s);
            s = s.normalized();
            if (s.id.ptr != q.style.id.ptr) s = try self.internStyle(s);
            if (!s.eql(q.style)) {
                q.style = s;
                q.revision = self.revise();
                changed = true;
            }
        }
        return changed;
    }

    /// Interns attributes into the text's storage, so that they stay
    /// valid while the text lives.
    pub fn intern(self: *Text, a: Attributes) !Attributes {
        return self.pool.internAttributes(self.allocator, a);
    }

    /// Interns a string into the text's storage.
    pub fn internString(self: *Text, s: []const u8) ![]const u8 {
        return self.pool.intern(self.allocator, s);
    }

    /// Runs of the text from rune start to end, with the rune each starts
    /// at: the newline ending a paragraph is a run of its own unless it
    /// joins the last run of its paragraph with the same attributes.
    pub fn rangeRuns(self: *const Text, start: u32, end: u32) RangeIterator {
        const n = self.len();
        const a = @min(start, n);
        const z = @min(end, n);
        const p = if (a < z) self.paraAt(a) else 0;
        return .{ .text = self, .start = a, .end = z, .para = p, .at = if (a < z) self.paraStart(p) else z };
    }
};

/// Runs of a range of a Text: a paragraph's newline comes as a run of
/// its own, "\n".
pub const RangeIterator = struct {
    text: *const Text,
    start: u32,
    end: u32,
    para: u32,
    /// Rune the current paragraph starts at.
    at: u32,
    run: usize = 0,
    /// Rune the current run starts at, within its paragraph.
    run_at: u32 = 0,
    newline: ?Item = null,

    pub const Item = struct { start: u32, run: Run };

    pub fn next(self: *RangeIterator) ?Item {
        const t = self.text;
        if (self.newline) |item| {
            self.newline = null;
            return item;
        }
        while (self.para < t.paras.items.len and self.at < self.end) {
            const q = &t.paras.items[self.para];
            while (self.run < q.runs.items.len) {
                const r = q.runs.items[self.run];
                const ra = self.at + self.run_at;
                self.run += 1;
                self.run_at += r.n;
                if (ra >= self.end) return null;
                const a = @max(ra, self.start);
                const z = @min(ra + r.n, self.end);
                if (a >= z) continue;
                const la = a - self.at;
                const lz = z - self.at;
                var item: ?Item = null;
                if (la < q.n) item = .{ .start = a, .run = .{ .text = q.bytes.items[q.byteOf(la)..q.byteOf(@min(lz, q.n))], .attributes = r.a } };
                if (lz > q.n) {
                    const nl: Item = .{ .start = self.at + q.n, .run = .{ .text = "\n", .attributes = r.a } };
                    if (item == null) return nl;
                    self.newline = nl;
                }
                return item;
            }
            self.at += q.n + 1;
            self.para += 1;
            self.run = 0;
            self.run_at = 0;
        }
        return null;
    }
};
