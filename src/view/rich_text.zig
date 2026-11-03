//! Rich text: runs of text with styles of their own (size, weight, slant,
//! fixed pitch, color, underline, wavy underline, strikethrough and a
//! background) that wrap together as one paragraph, or several at newlines,
//! as a self-measuring view leaf.
//!
//! `setSpans` measures the spans' words once, on the main thread outside
//! paint, and reserves room for every run and line; `setWidth` wraps them
//! again without allocating or measuring text, so a host can follow a width
//! change cheaply. Measure and paint only read the wrapped runs. Each run
//! draws as a single-line label in its span's font, so text is shaped
//! within a run but not across runs; give the leaf the Measurer the view
//! host uses so that runs and their decorations line up with the glyphs.
//!
//! Paragraphs of prose can be set as a book sets them: `Options.justify`
//! stretches wrapped lines to the width, `Options.indent` moves the first
//! line in, `Options.line_height` gives lines more leading, a soft hyphen
//! (U+00AD) is a place a line may break at and shows as a hyphen only
//! there, and `Span.baseline_shift` raises or lowers a span, as
//! superscripts and subscripts are. `lines` tells where each line is, to
//! break pages between them.
const std = @import("std");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");

pub const Font = view.Font;
pub const Rect = view.Rect;
pub const Point = view.Point;
pub const Size = view.Size;
pub const Frame = ui.Frame;

/// The box of an inline object: `width` wide, `height` above the baseline
/// and `descent` below it, as math's subscripts and fractions reach.
pub const Object = struct { width: f32, height: f32, descent: f32 = 0 };

/// Draws the inline objects of a RichText (`Span.object`) in their boxes,
/// after its text: an image, a formula. `span` is the object's span.
pub const ObjectPainter = struct {
    context: *anyopaque,
    paint: *const fn (context: *anyopaque, frame: *Frame, span: usize, box: Rect) anyerror!void,
};

/// A run of a RichText with a style of its own. What it leaves null takes
/// the style of the text around it; `italic`, `monospace` and the lines
/// only turn those on.
pub const Span = struct {
    /// Borrowed: it must stay valid while the RichText holds the span.
    text: []const u8,
    size: ?f32 = null,
    weight: ?Font.Weight = null,
    italic: bool = false,
    monospace: bool = false,
    color: ?u32 = null,
    underline: bool = false,
    wavy_underline: bool = false,
    /// Underline with a line of square dots as thick as the line, every
    /// three DIP, or two dots apart when thicker, as a link marks hover.
    dotted_underline: bool = false,
    strikethrough: bool = false,
    /// Color and thickness of the span's lines; by default its text color
    /// and a thickness that grows with the font size.
    decoration_color: ?u32 = null,
    decoration_thickness: f32 = 0,
    /// Highlights the span, as search results are.
    background: ?u32 = null,
    /// Rounds the corners of the background, which then hugs the span's
    /// glyphs, a little wider than them, rather than filling the line, as
    /// code within text shows.
    radius: f32 = 0,
    /// Raises the span's text that many DIP above the baseline, or lowers
    /// it when negative, as superscripts and subscripts with a smaller
    /// `size` are: footnote references, exponents, chemical formulas. The
    /// line makes room for it, and its lines and background go with it.
    baseline_shift: f32 = 0,
    /// Makes the span an inline object: a box of this size standing on the
    /// baseline in place of its text, which lines break around and which
    /// `Options.objects` draws. Give it one U+FFFC as its text.
    object: ?Object = null,
};

pub const Options = struct {
    /// Measures runs in their fonts; use the one the view host uses.
    measurer: view.Measurer = .{},
    /// The font of the text around the spans.
    font: Font = .{},
    /// The text color around the spans; null takes the theme's.
    color: ?u32 = null,
    /// Width lines wrap at, in DIP; 0 breaks lines only at newlines.
    width: f32 = 0,
    /// Extra space between lines, in DIP.
    line_gap: f32 = 0,
    /// The height of a line as a multiple of the font's size, its extra
    /// room shared above and below the text: 1.8 gives CJK prose its usual
    /// leading. 0, or less than the text needs, keeps the line's own.
    line_height: f32 = 0,
    /// Stretches every line `width` wraps to `width`, but the last of each
    /// paragraph (before a newline or the end), by widening the spaces
    /// between its words and the room after Han characters and kana, as
    /// printed prose is set. A line with nothing to widen stays as it is.
    justify: bool = false,
    /// Moves the first line of the text this many DIP in, and wraps it
    /// that much narrower, as a book indents its paragraphs. Lines after a
    /// newline are not indented.
    indent: f32 = 0,
    /// Draws the spans that are inline objects; without it they draw
    /// nothing and keep their room.
    objects: ?ObjectPainter = null,
};

/// A wrapped piece of one span on one line, in DIP from the text's top
/// left corner.
pub const Run = struct {
    span: u32,
    /// Byte range of the run within its span's text.
    start: u32,
    end: u32,
    x: f32,
    /// Advance of the run, without the spaces that end its line and
    /// without its hyphen.
    width: f32,
    line: u32,
    /// The line breaks at a soft hyphen ending the run: a hyphen follows
    /// its text.
    hyphen: bool = false,
};

/// A line of the text, from its top: pages break between lines.
pub const Line = struct {
    y: f32,
    height: f32,
    /// Distance of the baseline below `y`.
    baseline: f32,
    /// How far the line's text reaches above and below its baseline; the
    /// rest of `height` is its leading.
    ascent: f32 = 0,
    descent: f32 = 0,
    /// Left edge of the text: the indent of the first line.
    x: f32 = 0,
    /// Width of the text from `x`, without the spaces that end it.
    width: f32,
    /// The bytes of the spans' texts, one after another, the line holds:
    /// the spaces that end it in, a newline ending it out.
    start: u32 = 0,
    end: u32 = 0,
};

/// A word with the spaces after it, or one CJK character: the pieces lines
/// break between.
const Word = struct {
    span: u32,
    start: u32,
    end: u32,
    width: f32,
    /// Width without the trailing spaces.
    visible: f32,
    /// A newline follows the word; `end` stops before it.
    hard_break: bool,
    /// No line break may come after the word: it ends inside a word that
    /// the next span continues.
    glued: bool,
    /// Visible width of the glued words starting here, which wrap together;
    /// for a word ending at a soft hyphen, the least room the line needs to
    /// take it, ending with its hyphen or going on.
    cluster: f32,
    /// Width of the hyphen a soft hyphen ending the word shows when a line
    /// breaks there; 0 without one.
    hyphen: f32 = 0,
    /// Justified lines widen the room after the word: it ends with spaces,
    /// or with a Han character, kana or their punctuation.
    stretch: bool = false,
};

/// Vertical metrics of a span's font.
const Metrics = struct { height: f32, ascent: f32, size: f32 };

/// Keep a RichText at a stable address while the view emits its embed.
pub const RichText = struct {
    allocator: std.mem.Allocator,
    options: Options,
    spans: []const Span = &.{},
    metrics: std.ArrayList(Metrics) = .empty,
    words: std.ArrayList(Word) = .empty,
    runs: std.ArrayList(Run) = .empty,
    lines: std.ArrayList(Line) = .empty,
    /// Where each span starts in the spans' texts one after another.
    bases: std.ArrayList(u32) = .empty,
    size: Size = .{ .width = 0, .height = 0 },
    /// Widest piece that cannot wrap.
    widest: f32 = 0,
    /// The theme's text color from the last measure.
    theme_text: u32 = view.Theme.light().palette.text,

    pub fn init(allocator: std.mem.Allocator, options: Options) RichText {
        return .{ .allocator = allocator, .options = options };
    }
    pub fn deinit(self: *RichText) void {
        self.metrics.deinit(self.allocator);
        self.words.deinit(self.allocator);
        self.runs.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.bases.deinit(self.allocator);
        self.* = undefined;
    }

    /// Show `spans`, borrowing them until the next call, measuring their
    /// words and wrapping them at `options.width`.
    pub fn setSpans(self: *RichText, spans: []const Span) !void {
        self.spans = spans;
        self.metrics.clearRetainingCapacity();
        self.words.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
        self.size = .{ .width = 0, .height = 0 };
        errdefer {
            self.spans = &.{};
            self.words.clearRetainingCapacity();
        }
        try self.metrics.ensureTotalCapacity(self.allocator, spans.len + 1);
        try self.bases.ensureTotalCapacity(self.allocator, spans.len);
        self.bases.clearRetainingCapacity();
        var base: u32 = 0;
        for (spans) |span| {
            self.metrics.appendAssumeCapacity(self.measureFont(self.fontOf(span)));
            self.bases.appendAssumeCapacity(base);
            base += @intCast(span.text.len);
        }
        self.metrics.appendAssumeCapacity(self.measureFont(self.options.font));
        for (spans, 0..) |span, index| try self.split(span, @intCast(index));
        self.glue();
        // A run per word at most, and a line per word plus the last.
        try self.runs.ensureTotalCapacity(self.allocator, self.words.items.len);
        try self.lines.ensureTotalCapacity(self.allocator, self.words.items.len + 1);
        self.wrap(self.options.width);
    }

    /// Wrap the spans at `width` (0 for newlines only) without allocating.
    pub fn setWidth(self: *RichText, width: f32) void {
        self.options.width = width;
        self.wrap(width);
    }

    /// The font span `span` draws in.
    pub fn fontOf(self: *const RichText, span: Span) Font {
        var font = self.options.font;
        if (span.size) |value| font.size = value;
        if (span.weight) |value| font.weight = value;
        font.italic = font.italic or span.italic;
        font.monospace = font.monospace or span.monospace;
        return font;
    }

    /// The box of the inline object of `run`, local to the text, or null
    /// when its span is no object.
    pub fn objectBox(self: *const RichText, run: Run) ?Rect {
        const span = self.spans[run.span];
        const o = span.object orelse return null;
        const line = self.lines.items[run.line];
        return .{ .x = run.x, .y = line.y + line.baseline - span.baseline_shift - o.height, .width = o.width, .height = o.height + o.descent };
    }

    /// The lines of the text as last wrapped, from the top.
    pub fn textLines(self: *const RichText) []const Line {
        return self.lines.items;
    }

    /// The span under `point`, local to the text, or null between lines
    /// and past their ends.
    pub fn spanAt(self: *const RichText, point: Point) ?usize {
        for (self.runs.items) |run| {
            const line = self.lines.items[run.line];
            if (point.y >= line.y and point.y < line.y + line.height and point.x >= run.x and point.x < run.x + run.width) return run.span;
        }
        return null;
    }

    fn measureFont(self: *const RichText, font: Font) Metrics {
        const height = self.options.measurer.textSize("Ag", font).height;
        // Labels center their text vertically; the baseline sits a little
        // below the middle.
        return .{ .height = height, .ascent = height / 2 + font.size * 0.35, .size = font.size };
    }

    fn split(self: *RichText, span: Span, index: u32) !void {
        const font = self.fontOf(span);
        const text = span.text;
        if (span.object) |o| {
            if (text.len == 0) return;
            try self.words.append(self.allocator, .{ .span = index, .start = 0, .end = @intCast(text.len), .width = o.width, .visible = o.width, .hard_break = false, .glued = false, .cluster = o.width });
            return;
        }
        var at: usize = 0;
        while (at < text.len) {
            const start = at;
            var hard_break = false;
            // The word: up to a space, newline or soft hyphen, or one CJK
            // character.
            var soft = false;
            while (at < text.len and !isSpace(text[at]) and text[at] != '\n') {
                if (isSoftHyphen(text, at)) {
                    soft = true;
                    break;
                }
                const length = sequenceLength(text[at]);
                if (breaksAround(decode(text[at..@min(text.len, at + length)]))) {
                    if (at == start) at += length;
                    break;
                }
                at += length;
            }
            const visible_end = at;
            // The soft hyphen belongs to the word and takes no room.
            if (soft) at += soft_hyphen.len;
            while (!soft and at < text.len and isSpace(text[at])) at += 1;
            const end = at;
            if (at < text.len and text[at] == '\n') {
                hard_break = true;
                at += 1;
            }
            const visible_width = self.options.measurer.textSize(text[start..visible_end], font).width;
            const spaced = std.mem.trimEnd(u8, text[start..end], "\r");
            const width = if (!soft and spaced.len > visible_end - start) self.options.measurer.textSize(spaced, font).width else visible_width;
            const hyphen = if (soft and !hard_break) self.options.measurer.textSize("-", font).width else 0;
            const stretch = end > visible_end and !soft or (visible_end > start and stretches(lastCodepoint(text[start..visible_end])));
            try self.words.append(self.allocator, .{ .span = index, .start = @intCast(start), .end = @intCast(end), .width = width, .visible = visible_width, .hard_break = hard_break, .glued = false, .cluster = visible_width, .hyphen = hyphen, .stretch = stretch });
        }
    }

    /// Mark words a span boundary cuts and total the clusters they form.
    fn glue(self: *RichText) void {
        const words = self.words.items;
        for (words, 0..) |*word, index| {
            if (index + 1 == words.len or word.hard_break or word.end == word.start or word.hyphen > 0) continue;
            const text = self.spanText(word.*);
            const next = words[index + 1];
            const next_text = self.spanText(next);
            if (next.span == word.span or next_text.len == 0) continue;
            if (self.spans[word.span].object != null or self.spans[next.span].object != null) continue;
            const last = lastCodepoint(text);
            word.glued = !isSpace(text[text.len - 1]) and !breaksAround(last) and !isSpace(next_text[0]) and !breaksAround(decode(next_text[0..@min(next_text.len, sequenceLength(next_text[0]))]));
        }
        self.widest = 0;
        var index = words.len;
        while (index > 0) {
            index -= 1;
            const word = &words[index];
            word.cluster = if (word.glued) word.width + words[index + 1].cluster else word.visible;
            // A line may end at a soft hyphen, with its hyphen, or go on.
            if (word.hyphen > 0) word.cluster = if (index + 1 < words.len) @min(word.visible + word.hyphen, word.width + words[index + 1].cluster) else word.visible;
            self.widest = @max(self.widest, word.cluster);
        }
    }

    fn spanText(self: *const RichText, word: Word) []const u8 {
        return self.spans[word.span].text[word.start..word.end];
    }

    fn wrap(self: *RichText, width: f32) void {
        self.runs.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
        const words = self.words.items;
        // The first line starts at the indent.
        var left: f32 = self.options.indent;
        var x: f32 = left;
        var trailing: f32 = 0;
        var line_runs: usize = 0;
        var widest: f32 = 0;
        var from: u32 = 0;
        for (words, 0..) |word, index| {
            const starts_cluster = index == 0 or !words[index - 1].glued;
            if (width > 0 and starts_cluster and x > left and x + word.cluster > width) {
                const previous = words[index - 1];
                self.finishLine(&line_runs, x - trailing, &widest, .{ .start = from, .end = self.offset(previous, previous.end), .hyphen = previous.hyphen, .justify = self.options.justify, .x = left });
                from = self.offset(word, word.start);
                left = 0;
                x = 0;
                trailing = 0;
            }
            if (word.end > word.start) {
                const runs = self.runs.items;
                // Justified lines move each word; a soft hyphen ends a run,
                // which shows its hyphen when the line breaks there.
                const joins = !self.options.justify and index > 0 and words[index - 1].hyphen == 0;
                if (joins and runs.len > line_runs and runs[runs.len - 1].span == word.span and runs[runs.len - 1].end == word.start) {
                    runs[runs.len - 1].end = word.end;
                    runs[runs.len - 1].width += word.width;
                } else self.runs.appendAssumeCapacity(.{ .span = word.span, .start = word.start, .end = word.end, .x = x, .width = word.width, .line = @intCast(self.lines.items.len) });
                x += word.width;
                trailing = word.width - word.visible;
            }
            if (word.hard_break) {
                self.finishLine(&line_runs, x - trailing, &widest, .{ .start = from, .end = self.offset(word, word.end), .x = left });
                from = self.offset(word, word.end + 1);
                left = 0;
                x = 0;
                trailing = 0;
            }
        }
        if (self.lines.items.len == 0 or self.runs.items.len > line_runs or x > left) {
            const end = if (words.len > 0) self.offset(words[words.len - 1], words[words.len - 1].end) else 0;
            self.finishLine(&line_runs, x - trailing, &widest, .{ .start = from, .end = @max(from, end), .x = left });
        }
        const last = self.lines.items[self.lines.items.len - 1];
        self.size = .{ .width = widest, .height = last.y + last.height };
    }

    /// Byte `at` of a word's span in the spans' texts one after another.
    fn offset(self: *const RichText, word: Word, at: u32) u32 {
        return self.bases.items[word.span] + at;
    }

    const Ending = struct {
        start: u32,
        end: u32,
        /// The line breaks at a soft hyphen, whose hyphen is this wide.
        hyphen: f32 = 0,
        /// The line wrapped: justified, it stretches to the width.
        justify: bool = false,
        x: f32 = 0,
    };

    /// Close the line holding runs `line_runs..`, its text reaching `right`.
    fn finishLine(self: *RichText, line_runs: *usize, right: f32, widest: *f32, ending: Ending) void {
        const runs = self.runs.items[line_runs.*..];
        const base = self.metrics.items[self.metrics.items.len - 1];
        var ascent: f32 = if (runs.len == 0) base.ascent else 0;
        var descent: f32 = if (runs.len == 0) base.height - base.ascent else 0;
        for (runs) |run| {
            const m = self.metrics.items[run.span];
            const span = self.spans[run.span];
            const shift = span.baseline_shift;
            // An object stands on the baseline, as high and as deep as it
            // is, whatever the font of its span.
            if (span.object) |o| {
                ascent = @max(ascent, o.height + shift);
                descent = @max(descent, o.descent - shift);
                continue;
            }
            ascent = @max(ascent, m.ascent + shift);
            descent = @max(descent, m.height - m.ascent - shift);
        }
        var width = @max(0, right);
        // Spaces that end the line take no room; a soft hyphen it breaks
        // at shows its hyphen.
        if (runs.len != 0) {
            const last = &runs[runs.len - 1];
            last.width = @max(0, right - last.x);
            if (ending.hyphen > 0) {
                last.hyphen = true;
                width += ending.hyphen;
            }
        }
        const room = self.options.width - width;
        if (ending.justify and self.options.width > 0 and room > 1e-3 and runs.len > 1) {
            var opportunities: usize = 0;
            for (runs[0 .. runs.len - 1]) |run| opportunities += @intFromBool(self.runStretches(run));
            if (opportunities > 0) {
                const each = room / @as(f32, @floatFromInt(opportunities));
                var moved: f32 = 0;
                for (runs) |*run| {
                    run.x += moved;
                    if (self.runStretches(run.*)) moved += each;
                }
                width = self.options.width;
            }
        }
        const y = if (self.lines.items.len == 0) 0 else blk: {
            const previous = self.lines.items[self.lines.items.len - 1];
            break :blk previous.y + previous.height + self.options.line_gap;
        };
        // Leading a line height asks for goes half above, half below.
        const height = @max(ascent + descent, self.options.line_height * self.options.font.size);
        const lead = (height - ascent - descent) / 2;
        self.lines.appendAssumeCapacity(.{ .y = y, .height = height, .baseline = lead + ascent, .ascent = ascent, .descent = descent, .x = ending.x, .width = @max(0, width - ending.x), .start = ending.start, .end = ending.end });
        widest.* = @max(widest.*, width);
        line_runs.* = self.runs.items.len;
    }

    /// Whether justification widens the room after a run: the word it
    /// ends with ends with spaces or a character that stretches.
    fn runStretches(self: *const RichText, run: Run) bool {
        if (self.spans[run.span].object != null) return false;
        const text = self.spans[run.span].text[run.start..run.end];
        if (text.len == 0) return false;
        if (isSpace(text[text.len - 1])) return true;
        if (endsWithSoftHyphen(text)) return false;
        return stretches(lastCodepoint(text));
    }

    /// Draw the text with its top left corner at `origin` on any target
    /// with `rect`, `roundedRect` and `labelFont`, such as a `ui.Frame`.
    pub fn paintTo(self: *const RichText, target: anytype, origin: Point) void {
        const base_color = self.options.color orelse self.theme_text;
        for (self.runs.items) |run| {
            const span = self.spans[run.span];
            if (span.object != null) continue;
            const color = span.background orelse continue;
            const line = self.lines.items[run.line];
            const size = self.metrics.items[run.span].size;
            if (span.radius > 0) {
                const pad = @min(size * 0.22, span.radius);
                const baseline = origin.y + line.y + line.baseline - span.baseline_shift;
                target.roundedRect(.{ .x = origin.x + run.x - pad, .y = baseline - size * 0.98, .width = run.width + 2 * pad, .height = size * 1.32 }, span.radius, ui.Color.rgb(color));
            } else target.rect(.{ .x = origin.x + run.x, .y = origin.y + line.y, .width = run.width, .height = line.height }, color);
        }
        for (self.runs.items) |run| {
            const span = self.spans[run.span];
            if (span.object != null) continue;
            const line = self.lines.items[run.line];
            const m = self.metrics.items[run.span];
            const color = span.color orelse base_color;
            const text = visibleText(span.text[run.start..run.end]);
            const baseline = origin.y + line.y + line.baseline - span.baseline_shift;
            const top = baseline - m.ascent;
            if (text.len != 0) {
                // Room past the measured width keeps a label from eliding
                // text a native font sets a little wider.
                target.labelFont(.{ .x = origin.x + run.x, .y = top, .width = run.width + m.size, .height = m.height }, text, color, self.fontOf(span));
            }
            var width = run.width;
            if (run.hyphen) {
                const hyphen = self.options.measurer.textSize("-", self.fontOf(span)).width;
                target.labelFont(.{ .x = origin.x + run.x + run.width, .y = top, .width = hyphen + m.size, .height = m.height }, "-", color, self.fontOf(span));
                width += hyphen;
            }
            if (!(span.underline or span.wavy_underline or span.dotted_underline or span.strikethrough) or width <= 0) continue;
            const thickness = if (span.decoration_thickness > 0) span.decoration_thickness else @max(1, @round(m.size / 14));
            const line_color = span.decoration_color orelse color;
            const x = origin.x + run.x;
            if (span.wavy_underline) wave(target, x, baseline + @max(1, m.size * 0.08), width, thickness, line_color) else if (span.dotted_underline) dots(target, x, baseline + @max(1, m.size * 0.08), width, thickness, line_color) else if (span.underline)
                target.rect(.{ .x = x, .y = baseline + @max(1, m.size * 0.08), .width = width, .height = thickness }, line_color);
            if (span.strikethrough) target.rect(.{ .x = x, .y = baseline - m.size * 0.3 - thickness / 2, .width = width, .height = thickness }, line_color);
        }
    }

    /// The view leaf; the RichText must stay at this address while any
    /// pass that emits it runs.
    pub fn embed(self: *RichText) view.Embed {
        return .{ .context = self, .measure = measureEmbed, .paint = paintEmbed };
    }
    fn measureEmbed(context: *anyopaque, theme: view.Theme) ui.layout.Measurement {
        const self: *RichText = @ptrCast(@alignCast(context));
        self.theme_text = theme.palette.text;
        return .{ .minimum = self.size, .preferred = self.size };
    }
    fn paintEmbed(context: *anyopaque, frame: *ui.Frame, _: u64, bounds: Rect) anyerror!void {
        const self: *RichText = @ptrCast(@alignCast(context));
        try frame.pushClip(bounds);
        defer frame.popClip() catch {};
        self.paintTo(frame, .{ .x = bounds.x, .y = bounds.y });
        const painter = self.options.objects orelse return;
        for (self.runs.items) |run| {
            const box = self.objectBox(run) orelse continue;
            try painter.paint(painter.context, frame, run.span, .{ .x = bounds.x + box.x, .y = bounds.y + box.y, .width = box.width, .height = box.height });
        }
    }
};

/// A wavy line `width` long whose top sits near `y`: a triangle wave in
/// steps two thicknesses wide.
fn wave(target: anytype, x: f32, y: f32, width: f32, thickness: f32, color: u32) void {
    const step = 2 * thickness;
    const offsets = [_]f32{ 0, 1, 2, 1 };
    var at: f32 = 0;
    var phase: usize = 0;
    while (at < width) : ({
        at += step;
        phase = (phase + 1) % offsets.len;
    }) target.rect(.{ .x = x + at, .y = y + offsets[phase] * thickness * 0.75, .width = @min(step, width - at), .height = thickness }, color);
}

/// Square dots as thick as the line whose top sits at `y`, `width` long,
/// every three DIP or two dots' widths apart when they are thicker.
fn dots(target: anytype, x: f32, y: f32, width: f32, thickness: f32, color: u32) void {
    const size = @max(1, @round(thickness));
    const step = @max(3, 2 * size);
    var at: f32 = 0;
    while (at < width) : (at += step) target.rect(.{ .x = x + at, .y = y, .width = @min(size, width - at), .height = size }, color);
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}
/// U+00AD SOFT HYPHEN: a place a line may break at, showing a hyphen there
/// and nothing elsewhere.
const soft_hyphen = "\u{ad}";
fn isSoftHyphen(text: []const u8, at: usize) bool {
    return std.mem.startsWith(u8, text[at..], soft_hyphen);
}
fn endsWithSoftHyphen(text: []const u8) bool {
    return std.mem.endsWith(u8, text, soft_hyphen);
}
/// The text a run draws: without the spaces that end it or a soft hyphen.
fn visibleText(text: []const u8) []const u8 {
    var t = std.mem.trimEnd(u8, text, " \t\r");
    if (endsWithSoftHyphen(t)) t = t[0 .. t.len - soft_hyphen.len];
    return t;
}
/// Whether justified lines widen the room after a character: a Han
/// character, kana, bopomofo or the punctuation written with them, which
/// lines of Chinese and Japanese take apart, or a space.
fn stretches(codepoint: u21) bool {
    return switch (codepoint) {
        ' ', 0xa0, 0x1361, 0x3000, 0x2e80...0x2fdf, 0x3001...0x303f, 0x3041...0x30ff, 0x3105...0x312f, 0x31a0...0x31ff, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xf900...0xfaff, 0xff01...0xff60, 0xff66...0xff9d, 0x20000...0x3fffd => true,
        else => false,
    };
}
fn sequenceLength(byte: u8) usize {
    return std.unicode.utf8ByteSequenceLength(byte) catch 1;
}
fn decode(bytes: []const u8) u21 {
    return std.unicode.utf8Decode(bytes) catch 0xfffd;
}
fn lastCodepoint(text: []const u8) u21 {
    var start = text.len - 1;
    while (start > 0 and text[start] & 0xc0 == 0x80) start -= 1;
    return decode(text[start..]);
}
/// Characters a line may break before or after, as in CJK text.
fn breaksAround(codepoint: u21) bool {
    return switch (codepoint) {
        0x1100...0x115f, 0x2e80...0x303e, 0x3041...0x33ff, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xa000...0xa4cf, 0xac00...0xd7a3, 0xf900...0xfaff, 0xfe30...0xfe4f, 0xff00...0xff60, 0xffe0...0xffe6, 0x20000...0x3fffd => true,
        else => false,
    };
}

test {
    _ = @import("rich_text_tests.zig");
}
