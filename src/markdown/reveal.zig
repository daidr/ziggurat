//! How a streamed Markdown reply comes in: rather than in the bursts a
//! network delivers, at an even pace that catches up with what came
//! within `Reveal.catch_up_ns`, a unit at a time, each fading in, as chat
//! apps show replies. `RevealState.show` picks the prefix of the source a
//! pass shows; the view fades in what showed a moment ago and tells, by
//! `RevealState.revealed`, when all of it shows.
const std = @import("std");

/// What `Reveal` shows at a time.
pub const Unit = enum {
    /// A word and the spaces after it. In Chinese and Japanese, written
    /// without spaces, each ideograph and kana is a word.
    word,
    /// A character at a time.
    character,
    /// A sentence at a time, once it is complete: up to a period, a
    /// question or exclamation mark followed by a space, an ideographic
    /// full stop, or the end of a line.
    sentence,
    /// A line at a time, once it is complete.
    line,
    /// A paragraph, a block between blank lines, at a time, once it is
    /// complete.
    paragraph,
    /// Text as it comes, without pacing.
    at_once,
};

/// How `RevealState.show` paces text.
pub const Reveal = struct {
    unit: Unit = .word,
    /// How long text that came waits at most before it shows: 250 ms when
    /// zero. Text comes in faster the more there is waiting.
    catch_up_ns: u64 = 0,
    /// How long text takes to fade in: 300 ms when zero, none when
    /// negative, nor when the desktop asks for less motion.
    fade_ns: i64 = 0,
};

/// Opacity levels text fades through, so that the spans of text alike
/// stay one.
const levels = 16;
/// The most moments of text fading in at once; older ones merge.
const max_marks = 96;

const Mark = struct {
    /// Where the text that showed at `time` starts, counted in the text
    /// the view builds (`RevealState.counted`).
    at: usize,
    time: u64,
};

/// How much of a source a view shows and since when what it shows came
/// in, kept by the application with the view across passes, one for each
/// streamed document.
pub const RevealState = struct {
    /// A stream being revealed, or done with text left to reveal.
    revealing: bool = false,
    /// Bytes of the source shown, and a hash of them, to tell more of the
    /// same text from an edit.
    shown: usize = 0,
    shown_hash: u64 = 0,
    /// The length of the source of the last pass.
    length: usize = 0,
    carry: f64 = 0,
    last: u64 = 0,
    started: bool = false,
    marks: [max_marks]Mark = undefined,
    mark_count: usize = 0,
    /// The text the view built in the last pass, as counted by its
    /// builder: where text shown next starts.
    counted: usize = 0,
    /// Set by `show` for the pass: the fade, null for none.
    fade_ns: ?u64 = null,
    now: u64 = 0,

    /// The prefix of `source` the pass at `now` (in ns, as `View.time`)
    /// shows, given whether more of it is still `streaming` in. Parse it,
    /// and build it with `Options.reveal` set to this state, which fades
    /// in what came a moment ago. `next` is set to when the next frame is
    /// due while text is still to show or fade, else null. Text a stream
    /// left to reveal still comes in once it is done; other text a
    /// finished document is given shows at once, as an edit does.
    pub fn show(self: *RevealState, source: []const u8, streaming: bool, now: u64, reduce_motion: bool, reveal: Reveal, next: *?u64) []const u8 {
        next.* = null;
        self.now = now;
        const edited = self.shown > source.len or (self.shown > 0 and std.hash.Wyhash.hash(0, source[0..self.shown]) != self.shown_hash);
        const pending = self.revealing and self.shown < self.length and !edited;
        self.length = source.len;
        defer self.fadeFor(now, reduce_motion, reveal, next);
        if (edited) {
            // Another text, not more of it: nothing of it fades from before.
            self.mark_count = 0;
            self.counted = 0;
        }
        if ((!streaming and !pending) or reveal.unit == .at_once or edited) {
            self.setShown(source, source.len);
            self.last = now;
            self.started = true;
            self.revealing = streaming;
            return source;
        }
        self.revealing = true;
        var target = source.len;
        if (streaming and reveal.unit != .word and reveal.unit != .character) {
            // Only complete sentences, lines or paragraphs, while more is
            // coming.
            target = self.shown;
            var i = self.shown;
            while (unitEnd(source, i, source.len, reveal.unit)) |end| {
                target = end;
                i = end;
            }
        }
        if (self.shown >= target) {
            // Nothing to show until more text comes, which builds a pass.
            self.last = now;
            self.started = true;
            return source[0..self.shown];
        }
        var dt: u64 = if (now > self.last) now - self.last else 0;
        if (!self.started or dt > 100 * std.time.ns_per_ms) dt = 16 * std.time.ns_per_ms;
        self.last = now;
        self.started = true;
        const catch_up: f64 = @floatFromInt(if (reveal.catch_up_ns == 0) 250 * std.time.ns_per_ms else reveal.catch_up_ns);
        const backlog: f64 = @floatFromInt(target - self.shown);
        // As many bytes a second as show the backlog within the catch-up
        // time, and at least a few hundred, so that a trickle does not
        // crawl.
        const rate = @max(backlog / (catch_up / std.time.ns_per_s), 240);
        self.carry += rate * @as(f64, @floatFromInt(dt)) / std.time.ns_per_s;
        const n: usize = @intFromFloat(@floor(self.carry));
        if (n == 0) {
            next.* = now;
            return source[0..self.shown];
        }
        self.carry -= @floatFromInt(n);
        const ahead = snap(source, @min(self.shown + n, target), target, reveal.unit);
        if (ahead > self.shown) {
            self.addMark(.{ .at = self.counted, .time = now });
            self.setShown(source, ahead);
        }
        if (self.shown < source.len) next.* = now;
        return source[0..self.shown];
    }

    fn setShown(self: *RevealState, source: []const u8, shown: usize) void {
        self.shown = shown;
        self.shown_hash = std.hash.Wyhash.hash(0, source[0..shown]);
    }

    fn addMark(self: *RevealState, mark: Mark) void {
        if (self.mark_count == max_marks) {
            std.mem.copyForwards(Mark, self.marks[0 .. max_marks - 1], self.marks[1..max_marks]);
            self.mark_count -= 1;
        }
        self.marks[self.mark_count] = mark;
        self.mark_count += 1;
    }

    /// Drops the marks done fading and decides the pass's fade.
    fn fadeFor(self: *RevealState, now: u64, reduce_motion: bool, reveal: Reveal, next: *?u64) void {
        const fade: ?u64 = if (reveal.fade_ns < 0) null else if (reveal.fade_ns == 0) 300 * std.time.ns_per_ms else @intCast(reveal.fade_ns);
        var k: usize = 0;
        while (k < self.mark_count and (fade == null or now -| self.marks[k].time >= fade.?)) k += 1;
        std.mem.copyForwards(Mark, self.marks[0 .. self.mark_count - k], self.marks[k..self.mark_count]);
        self.mark_count -= k;
        if (self.mark_count == 0 or fade == null or reduce_motion) {
            self.mark_count = 0;
            self.fade_ns = null;
            return;
        }
        self.fade_ns = fade;
        next.* = now;
    }

    /// The opacity of the text the view builds at `at`, counted as
    /// `counted` counts: 1 for text done fading in.
    pub fn opacity(self: *const RevealState, at: usize) f32 {
        const fade = self.fade_ns orelse return 1;
        if (self.mark_count == 0 or at < self.marks[0].at) return 1;
        // The last mark at or before `at`.
        var lo: usize = 0;
        var hi = self.mark_count;
        while (lo < hi) {
            const m = (lo + hi) / 2;
            if (self.marks[m].at <= at) lo = m + 1 else hi = m;
        }
        const age: f32 = @floatFromInt(self.now -| self.marks[lo - 1].time);
        const amount = age / @as(f32, @floatFromInt(fade));
        return @min(1, @floor(easeOut(amount) * levels) / levels);
    }

    /// Whether text still fades in.
    pub fn fading(self: *const RevealState) bool {
        return self.fade_ns != null and self.mark_count > 0;
    }

    /// Whether all of the source of the last pass shows, done fading in.
    /// A chat shows a reply's time and actions once its reply is complete
    /// and revealed, not as its last bytes arrive, while words still come
    /// in. Read it after building the pass. Text that shows at once
    /// (`Unit.at_once`, a finished document no stream left to reveal, an
    /// edit) is revealed in the pass it comes; without a fade (a negative
    /// `Reveal.fade_ns`, or reduced motion), once its last unit shows. More
    /// text makes it false again. Of a stream, it tells only that the text
    /// that came so far shows: whether more is coming is the caller's to
    /// know, and text held back for a sentence, a line or a paragraph to
    /// end keeps it false until the stream is done.
    pub fn revealed(self: *const RevealState) bool {
        return self.started and self.shown >= self.length and !self.fading();
    }
};

fn easeOut(t: f32) f32 {
    const u = 1 - std.math.clamp(t, 0, 1);
    return 1 - u * u * u;
}

fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

/// Moves offset `at` of `source` forward to the end of the unit it is in.
fn snap(source: []const u8, at: usize, target: usize, unit: Unit) usize {
    var i = at;
    switch (unit) {
        .word => {
            // Up to a space, or to an ideograph or a kana, each a word:
            // past the one `at` is in, else up to the next.
            while (i > 0 and i < source.len and isContinuation(source[i])) i -= 1;
            while (i < target and source[i] != ' ' and source[i] != '\n') {
                const n = std.unicode.utf8ByteSequenceLength(source[i]) catch 1;
                const codepoint = std.unicode.utf8Decode(source[i..@min(source.len, i + n)]) catch 0;
                if (standsAlone(codepoint)) {
                    if (i <= at) i += n;
                    break;
                }
                i += n;
            }
            i = @min(i, target);
            while (i < target and (source[i] == ' ' or source[i] == '\n')) i += 1;
        },
        .sentence, .line, .paragraph => i = unitEnd(source, i, target, unit) orelse target,
        .character, .at_once => {},
    }
    while (i < target and isContinuation(source[i])) i += 1;
    return i;
}

/// Where the first sentence, line or paragraph of `source` ending after
/// `at` and by `limit` ends.
fn unitEnd(source: []const u8, at: usize, limit: usize, unit: Unit) ?usize {
    switch (unit) {
        .line => if (std.mem.indexOfScalar(u8, source[at..limit], '\n')) |k| return at + k + 1,
        .paragraph => if (std.mem.indexOf(u8, source[at..limit], "\n\n")) |k| return at + k + 2,
        .sentence => {
            var j = at;
            while (j < limit) {
                const n = @min(std.unicode.utf8ByteSequenceLength(source[j]) catch 1, limit - j);
                const codepoint = std.unicode.utf8Decode(source[j..][0..n]) catch 0;
                j += n;
                switch (codepoint) {
                    '\n' => return j,
                    '.', '!', '?', 0x2026 => {
                        // Closing quotes and brackets go with it, then a
                        // space.
                        while (j < limit and std.mem.indexOfScalar(u8, "\"')]*_", source[j]) != null) j += 1;
                        if (j < limit and (source[j] == ' ' or source[j] == '\n')) return j + 1;
                    },
                    0x3002, 0xff01, 0xff1f => return j,
                    else => {},
                }
            }
        },
        else => {},
    }
    return null;
}

/// Whether `r` is a word on its own: a Han ideograph, a Hiragana or a
/// Katakana, with the prolonged sound mark.
fn standsAlone(r: u21) bool {
    return switch (r) {
        0x2e80...0x2fdf, 0x3005, 0x3007, 0x3021...0x3029, 0x3038...0x303b, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xf900...0xfaff, 0x20000...0x3fffd => true,
        0x3041...0x3096, 0x309d...0x309f, 0x30a1...0x30fa, 0x30fc...0x30ff, 0x31f0...0x31ff, 0xff66...0xff9d, 0x1b000...0x1b16f => true,
        else => false,
    };
}

const ms = std.time.ns_per_ms;

fn showAt(state: *RevealState, source: []const u8, streaming: bool, now: u64, reveal: Reveal) []const u8 {
    var next: ?u64 = null;
    return state.show(source, streaming, now, false, reveal, &next);
}

test "a stream reveals words at a pace that catches up" {
    var state: RevealState = .{};
    const text = "one two three four five six seven eight nine ten";
    var now: u64 = 1000 * ms;
    const first = showAt(&state, text[0..3], true, now, .{});
    // A word or so in the first frame, never half of one.
    try std.testing.expect(first.len == 0 or first.len == 3);
    var shown = first.len;
    var frames: usize = 0;
    while (shown < text.len and frames < 100) : (frames += 1) {
        now += 16 * ms;
        const prefix = showAt(&state, text, true, now, .{});
        try std.testing.expect(prefix.len >= shown);
        // Each prefix ends after a word's spaces or at the end.
        try std.testing.expect(prefix.len == text.len or prefix.len == 0 or text[prefix.len - 1] == ' ');
        shown = prefix.len;
    }
    // About the catch-up time, 250 ms, to show it all.
    try std.testing.expect(frames <= 20);
    try std.testing.expect(!state.revealed());
    // It is revealed once the fade of the last words ends.
    now += 400 * ms;
    _ = showAt(&state, text, false, now, .{});
    try std.testing.expect(state.revealed());
}

test "finished text shows at once and is revealed" {
    var state: RevealState = .{};
    try std.testing.expectEqualStrings("# Hi", showAt(&state, "# Hi", false, 5 * ms, .{}));
    try std.testing.expect(state.revealed());
    // An edit shows at once too.
    try std.testing.expectEqualStrings("# Ho there", showAt(&state, "# Ho there", true, 10 * ms, .{}));
    try std.testing.expect(state.revealed());
    // At once, without pacing.
    var at_once: RevealState = .{};
    try std.testing.expectEqualStrings("a b c", showAt(&at_once, "a b c", true, 1, .{ .unit = .at_once }));
    try std.testing.expect(at_once.revealed());
}

test "text a stream left to reveal keeps coming once it is done" {
    var state: RevealState = .{};
    var now: u64 = 1;
    _ = showAt(&state, "", true, now, .{});
    now += 16 * ms;
    const text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho";
    const prefix = showAt(&state, text, true, now, .{});
    try std.testing.expect(prefix.len < text.len);
    now += 16 * ms;
    const after = showAt(&state, text, false, now, .{});
    try std.testing.expect(after.len >= prefix.len and after.len < text.len);
    try std.testing.expect(!state.revealed());
    var frames: usize = 0;
    while (!state.revealed() and frames < 100) : (frames += 1) {
        now += 16 * ms;
        _ = showAt(&state, text, false, now, .{ .fade_ns = -1 });
    }
    try std.testing.expect(state.revealed());
    try std.testing.expect(state.shown == text.len);
}

test "sentences, lines and paragraphs show once complete" {
    var state: RevealState = .{};
    var now: u64 = 1;
    const reveal: Reveal = .{ .unit = .sentence, .fade_ns = -1 };
    _ = showAt(&state, "", true, now, reveal);
    var prefix: []const u8 = "";
    for (0..30) |_| {
        now += 16 * ms;
        prefix = showAt(&state, "Hello there. How are", true, now, reveal);
    }
    try std.testing.expectEqualStrings("Hello there. ", prefix);
    for (0..30) |_| {
        now += 16 * ms;
        prefix = showAt(&state, "Hello there. How are you?", false, now, reveal);
    }
    try std.testing.expectEqualStrings("Hello there. How are you?", prefix);

    try std.testing.expectEqual(@as(?usize, 3), unitEnd("ab\ncd", 0, 5, .line));
    try std.testing.expectEqual(@as(?usize, 4), unitEnd("ab\n\ncd", 0, 6, .paragraph));
    try std.testing.expectEqual(@as(?usize, 9), unitEnd("好的。是", 0, 12, .sentence));
    try std.testing.expectEqual(@as(?usize, 6), unitEnd("Hi!\") x", 0, 7, .sentence));
    try std.testing.expectEqual(@as(?usize, null), unitEnd("e.g", 0, 3, .sentence));
}

test "a word snaps past ideographs one at a time" {
    try std.testing.expectEqual(@as(usize, 3), snap("你好世界", 1, 12, .word));
    try std.testing.expectEqual(@as(usize, 3), snap("ab cd", 1, 5, .word));
    try std.testing.expectEqual(@as(usize, 3), snap("añ", 2, 3, .character));
}

test "text fades in by when it showed" {
    var state: RevealState = .{};
    var next: ?u64 = null;
    _ = state.show("", true, 0, false, .{}, &next);
    state.counted = 0;
    var now: u64 = 16 * ms;
    _ = state.show("one two three four five six", true, now, false, .{}, &next);
    try std.testing.expect(next != null);
    // Fresh text is faint; text before the first mark is opaque.
    try std.testing.expect(state.opacity(0) < 0.5);
    state.counted = 4;
    now += 150 * ms;
    _ = state.show("one two three four five six", true, now, false, .{}, &next);
    try std.testing.expect(state.opacity(0) > 0.5 and state.opacity(0) < 1);
    try std.testing.expect(state.opacity(5) < state.opacity(0));
    now += 400 * ms;
    _ = state.show("one two three four five six", false, now, false, .{}, &next);
    try std.testing.expectEqual(@as(f32, 1), state.opacity(0));
    // Reduced motion fades nothing.
    var still: RevealState = .{};
    _ = still.show("", true, 0, true, .{}, &next);
    _ = still.show("one two", true, 16 * ms, true, .{}, &next);
    try std.testing.expect(!still.fading());
    try std.testing.expectEqual(@as(f32, 1), still.opacity(0));
}
