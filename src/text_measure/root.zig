//! A `view.Measurer` that measures with the platform's text layout, in the
//! families the renderers draw with, so that views and the rich text editor
//! place text as it is drawn. Widths are cached by text and font; text the
//! layout does not take is estimated.
//!
//! Two kinds of text skip a layout of their own. A number, such as the
//! values of a dashboard that change in every frame, is put together from
//! the advances of its characters and the kerning of each pair of them,
//! each laid out once a font. A paragraph of plain Latin text wrapped at a
//! new width takes its lines from the paragraph shaped once as one line, the
//! width of a line being where its last character ends less where its first
//! starts, as the text engines keep the advances of the glyphs a whole text
//! was shaped with when they break it into lines. The first of these widths
//! in each font are checked against a layout of their own, and a font that
//! disagrees is laid out every time.
const std = @import("std");
const builtin = @import("builtin");
const view = @import("ziggurat_view");
const text = @import("ziggurat_text_layout");
const fonts = @import("ziggurat_fonts");

const Allocator = std.mem.Allocator;
const Font = view.Font;
const Size = view.Size;

/// The families the renderers draw the interface and fixed-pitch text in.
pub const interface_family = if (builtin.os.tag == .windows) "Segoe UI" else "Sans";
pub const monospace_family = if (builtin.os.tag == .windows) "Consolas" else "Monospace";

/// Create and use on the main thread.
pub const Native = struct {
    allocator: Allocator,
    engine: *text.Engine,
    widths: std.AutoHashMapUnmanaged(Key, f32) = .empty,
    /// Advances of single characters (`second` 0) and of pairs of them, as
    /// laid out, for numbers.
    glyphs: std.AutoHashMapUnmanaged(Pair, f32) = .empty,
    /// The paragraphs shaped once: where each byte starts on the line.
    shaped: std.AutoHashMapUnmanaged(Key, []f32) = .empty,
    trust: std.AutoHashMapUnmanaged(u32, Trust) = .empty,
    stats: Stats = .{},

    const Key = struct { hash: u64, font: u64 };
    const Pair = struct { font: u32, first: u8, second: u8 };
    const Trust = struct { numbers_checked: u8 = 0, numbers_off: bool = false, parts_checked: u8 = 0, parts_off: bool = false };
    const max_entries = 8192;
    const max_shaped = 64;
    /// Longest paragraph shaped once, in bytes, and longest number.
    const max_paragraph = 4096;
    const max_number = 32;
    /// How many of each kind of width are checked in each font.
    const checks = 8;
    /// Most a width put together may differ from a layout of its own, DIP.
    const tolerance: f32 = 0.25;

    pub const Stats = struct {
        /// Texts the platform laid out.
        layouts: u64 = 0,
        /// Numbers put together from their characters.
        numbers: u64 = 0,
        /// Parts of a paragraph measured from it shaped once.
        parts: u64 = 0,
        /// Fonts found to disagree, and laid out every time since.
        distrusted: u32 = 0,
    };

    pub fn create(allocator: Allocator, main_thread: std.Thread.Id) !*Native {
        const self = try allocator.create(Native);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .engine = try text.Engine.create(allocator, main_thread, .{}) };
        return self;
    }

    pub fn destroy(self: *Native) void {
        self.widths.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        self.dropShaped();
        self.shaped.deinit(self.allocator);
        self.trust.deinit(self.allocator);
        self.engine.close() catch {};
        self.allocator.destroy(self);
    }

    pub fn measurer(self: *Native) view.Measurer {
        return .{ .context = self, .measure = measureLabel, .measure_font = measureFont, .measure_part = measurePart };
    }

    fn dropShaped(self: *Native) void {
        var values = self.shaped.valueIterator();
        while (values.next()) |starts| self.allocator.free(starts.*);
        self.shaped.clearRetainingCapacity();
    }

    /// The width of `utf8` in `font`, in DIP.
    pub fn width(self: *Native, utf8: []const u8, font: Font) f32 {
        if (utf8.len == 0) return 0;
        const key: Key = .{ .hash = std.hash.Wyhash.hash(0, utf8), .font = font.measureKey() };
        if (self.widths.get(key)) |w| return w;
        const w = self.numberWidth(utf8, font, @bitCast(font.key())) orelse
            if (self.rawWidth(utf8, font)) |raw| @ceil(raw) else |_| estimate(utf8, font);
        if (self.widths.count() >= max_entries) self.widths.clearRetainingCapacity();
        self.widths.put(self.allocator, key, w) catch {};
        return w;
    }

    fn options(font: Font) text.Options {
        const family = if (font.family != 0) fonts.systemName(font.family) else if (font.monospace) monospace_family else interface_family;
        return .{ .family = family, .size = font.size, .weight = font.weight.value(), .italic = font.italic, .letter_spacing = font.letter_spacing };
    }

    /// The advance of `utf8` laid out on its own, not rounded.
    fn rawWidth(self: *Native, utf8: []const u8, font: Font) !f32 {
        self.stats.layouts += 1;
        const layout = try self.engine.layout(utf8, options(font));
        defer layout.close() catch {};
        const m = try layout.metrics();
        return m.bounds.width;
    }

    fn trustOf(self: *Native, font: u32) ?*Trust {
        const entry = self.trust.getOrPut(self.allocator, font) catch return null;
        if (!entry.found_existing) entry.value_ptr.* = .{};
        return entry.value_ptr;
    }

    /// Whether a width put together agrees with `utf8` laid out on its
    /// own, for the first widths of a kind in a font; the font is
    /// distrusted for that kind when not.
    fn agrees(self: *Native, utf8: []const u8, font: Font, value: f32, checked: *u8, off: *bool) ?f32 {
        if (checked.* >= checks) return value;
        const raw = self.rawWidth(utf8, font) catch return null;
        checked.* += 1;
        if (@abs(raw - value) <= tolerance) return value;
        off.* = true;
        self.stats.distrusted += 1;
        return raw;
    }

    /// A number put together from the advances of its characters and the
    /// kerning of each pair; null for text that is not one.
    fn numberWidth(self: *Native, utf8: []const u8, font: Font, font_key: u32) ?f32 {
        // Spaced letters are laid out, as the pairs measured are not.
        if (!isNumber(utf8) or font.letter_spacing != 0) return null;
        const trust = self.trustOf(font_key) orelse return null;
        if (trust.numbers_off) return null;
        var sum: f32 = 0;
        for (utf8, 0..) |char, index| {
            sum += self.glyph(font, font_key, char, 0) orelse return null;
            if (index + 1 < utf8.len) {
                const next_char = utf8[index + 1];
                const pair = self.glyph(font, font_key, char, next_char) orelse return null;
                const first = self.glyph(font, font_key, char, 0) orelse return null;
                const second = self.glyph(font, font_key, next_char, 0) orelse return null;
                sum += pair - first - second;
            }
        }
        const value = self.agrees(utf8, font, sum, &trust.numbers_checked, &trust.numbers_off) orelse return null;
        if (!trust.numbers_off) self.stats.numbers += 1;
        return @ceil(value);
    }

    fn glyph(self: *Native, font: Font, font_key: u32, first: u8, second: u8) ?f32 {
        const pair: Pair = .{ .font = font_key, .first = first, .second = second };
        if (self.glyphs.get(pair)) |value| return value;
        const chars = [2]u8{ first, second };
        const value = self.rawWidth(chars[0..if (second == 0) 1 else 2], font) catch return null;
        if (self.glyphs.count() >= max_entries) self.glyphs.clearRetainingCapacity();
        self.glyphs.put(self.allocator, pair, value) catch {};
        return value;
    }

    /// Width of a line of a paragraph of plain Latin text from where its
    /// characters start on the paragraph shaped as one line: for a part
    /// that starts the paragraph or follows a space, and ends it or comes
    /// before one. Null otherwise, and for text that breaks other ways.
    pub fn partWidth(self: *Native, whole: []const u8, start: usize, end: usize, font: Font) ?f32 {
        if (start >= end or end > whole.len or font.letter_spacing != 0) return null;
        var first = start;
        while (first > 0 and whole[first - 1] != '\n') first -= 1;
        var last = end;
        while (last < whole.len and whole[last] != '\n') last += 1;
        if (start != first and whole[start - 1] != ' ') return null;
        if (end != last and whole[end] != ' ') return null;
        const paragraph = whole[first..last];
        if (paragraph.len > max_paragraph or !plain(paragraph)) return null;
        const font_key: u32 = @bitCast(font.key());
        const trust = self.trustOf(font_key) orelse return null;
        if (trust.parts_off) return null;
        const key: Key = .{ .hash = std.hash.Wyhash.hash(0, paragraph), .font = font_key };
        const starts = self.shaped.get(key) orelse self.shape(key, paragraph, font) orelse return null;
        const raw = starts[end - first] - starts[start - first];
        const value = self.agrees(whole[start..end], font, raw, &trust.parts_checked, &trust.parts_off) orelse return null;
        if (!trust.parts_off) self.stats.parts += 1;
        return @ceil(value);
    }

    fn shape(self: *Native, key: Key, paragraph: []const u8, font: Font) ?[]f32 {
        self.stats.layouts += 1;
        const layout = self.engine.layout(paragraph, options(font)) catch return null;
        defer layout.close() catch {};
        const starts = self.allocator.alloc(f32, paragraph.len + 1) catch return null;
        for (starts, 0..) |*x, at| {
            const rect = layout.caret(.{ .byte_offset = at }) catch {
                self.allocator.free(starts);
                return null;
            };
            x.* = rect.x;
        }
        if (self.shaped.count() >= max_shaped) self.dropShaped();
        self.shaped.put(self.allocator, key, starts) catch {
            self.allocator.free(starts);
            return null;
        };
        return starts;
    }

    fn measurePart(context: ?*anyopaque, whole: []const u8, start: usize, end: usize, font: ?Font) ?f32 {
        const self: *Native = @ptrCast(@alignCast(context.?));
        return self.partWidth(whole, start, end, font orelse .{});
    }

    fn measureLabel(context: ?*anyopaque, utf8: []const u8) Size {
        const self: *Native = @ptrCast(@alignCast(context.?));
        return .{ .width = self.width(utf8, .{}), .height = view.Measurer.line_height };
    }

    fn measureFont(context: ?*anyopaque, utf8: []const u8, font: Font) Size {
        const self: *Native = @ptrCast(@alignCast(context.?));
        const scale = font.size / 16;
        const height = @max(view.Measurer.line_height * scale, @ceil(font.size * 1.25));
        return .{ .width = self.width(utf8, font), .height = height };
    }
};

/// Digits and the signs numbers are written with, as a dashboard shows
/// them: no letters, so no ligatures, and kerning only within pairs.
fn isNumber(utf8: []const u8) bool {
    if (utf8.len == 0 or utf8.len > Native.max_number) return false;
    var digits = false;
    for (utf8) |char| switch (char) {
        '0'...'9' => digits = true,
        '.', ',', ':', '-', '+', '%', '/' => {},
        else => return false,
    };
    return digits;
}

/// Printable ASCII with none of the brackets
/// or quotation marks that keep the words around spaces together; any
/// other text is laid out line by line.
fn plain(paragraph: []const u8) bool {
    for (paragraph) |char| switch (char) {
        '(', '[', '{', '"', '\'', '`' => return false,
        ' ', '!', '#'...'&', ')'...'Z', '\\', ']'...'_', 'a'...'z', '|', '}', '~' => {},
        else => return false,
    };
    return true;
}

/// What the default measurer gives, for text the layout does not take.
fn estimate(utf8: []const u8, font: Font) f32 {
    const m: view.Measurer = .{};
    return m.textSize(utf8, font).width;
}
