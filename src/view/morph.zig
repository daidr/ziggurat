//! Text morphing: the characters two texts share move from where they were
//! in the one to where they are in the other, growing or shrinking to
//! their size, and the others fade, as a shared element's text does when
//! `Match.morph` is set (`matched.zig`).
//!
//! Characters pair as the longest sequence of the same characters in both,
//! which keeps their order; those left over take the nearest of the same
//! characters left, as letters rearranged. A text longer than `max_chars`
//! characters does not pair: it fades.
const std = @import("std");

/// Characters of a text that morph; longer texts fade.
pub const max_chars = 64;

/// A character of a text laid out on one line: its bytes and its pen
/// offset and advance from the start of the line, in DIP.
pub const Char = struct { start: u16, len: u8, x: f32, width: f32 };

/// The characters of `text`, at most `out.len`, at the offsets `width`
/// gives each prefix: `width(context, text[0..n])` is the advance of the
/// first `n` bytes. Returns null when the text has more characters or is
/// not UTF-8.
pub fn layout(text: []const u8, out: []Char, context: anytype, width: fn (@TypeOf(context), []const u8) f32) ?[]Char {
    var view = std.unicode.Utf8View.init(text) catch return null;
    var it = view.iterator();
    var count: usize = 0;
    var x: f32 = 0;
    while (it.nextCodepointSlice()) |slice| {
        if (count == out.len) return null;
        const start = @intFromPtr(slice.ptr) - @intFromPtr(text.ptr);
        const end = start + slice.len;
        const next = width(context, text[0..end]);
        out[count] = .{ .start = @intCast(start), .len = @intCast(slice.len), .x = x, .width = @max(0, next - x) };
        x = @max(x, next);
        count += 1;
    }
    return out[0..count];
}

fn same(a_text: []const u8, a: Char, b_text: []const u8, b: Char) bool {
    return std.mem.eql(u8, a_text[a.start..][0..a.len], b_text[b.start..][0..b.len]);
}

/// Pair the characters `old` of `old_text` with those `new` of `new_text`:
/// `pairs[j]` is the character of `old` the `j`th of `new` comes from, -1
/// for none, and `taken[i]` marks those of `old` one comes from.
pub fn pair(old_text: []const u8, old: []const Char, new_text: []const u8, new: []const Char, pairs: []i16, taken: []bool) void {
    std.debug.assert(old.len <= max_chars and new.len <= max_chars);
    const n = old.len;
    const m = new.len;
    @memset(pairs[0..m], -1);
    @memset(taken[0..n], false);
    // lcs[i][j] is the length of the longest common sequence of the
    // characters of old from i and of new from j.
    var lcs: [max_chars + 1][max_chars + 1]u8 = undefined;
    for (0..m + 1) |j| lcs[n][j] = 0;
    for (0..n + 1) |i| lcs[i][m] = 0;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        var j: usize = m;
        while (j > 0) {
            j -= 1;
            lcs[i][j] = if (same(old_text, old[i], new_text, new[j])) lcs[i + 1][j + 1] + 1 else @max(lcs[i + 1][j], lcs[i][j + 1]);
        }
    }
    i = 0;
    var j: usize = 0;
    while (i < n and j < m) {
        if (same(old_text, old[i], new_text, new[j])) {
            pairs[j] = @intCast(i);
            taken[i] = true;
            i += 1;
            j += 1;
        } else if (lcs[i + 1][j] >= lcs[i][j + 1]) i += 1 else j += 1;
    }
    for (0..m) |k| {
        if (pairs[k] >= 0) continue;
        var best: ?usize = null;
        var distance: usize = 0;
        for (0..n) |o| {
            if (taken[o] or !same(old_text, old[o], new_text, new[k])) continue;
            // As far from it in old as it is in new, relatively.
            const a = o * m;
            const b = k * n;
            const d = if (a > b) a - b else b - a;
            if (best == null or d < distance) {
                best = o;
                distance = d;
            }
        }
        if (best) |o| {
            pairs[k] = @intCast(o);
            taken[o] = true;
        }
    }
}

/// How the one coming in fades in and the one going away fades out, as a
/// shared element's crossfade: opaque by half the way, gone over the
/// second half.
pub fn fadeIn(t: f32) f32 {
    return std.math.clamp(2 * t, 0, 1);
}
pub fn fadeOut(t: f32) f32 {
    return 1 - std.math.clamp(2 * t - 1, 0, 1);
}

fn testWidth(_: void, text: []const u8) f32 {
    return @floatFromInt(10 * (std.unicode.utf8CountCodepoints(text) catch text.len));
}

test "characters pair in order, and rearranged ones take the nearest" {
    var a: [max_chars]Char = undefined;
    var b: [max_chars]Char = undefined;
    const old = layout("Photos", &a, {}, testWidth).?;
    const new = layout("Photo 12", &b, {}, testWidth).?;
    try std.testing.expectEqual(@as(usize, 8), new.len);
    try std.testing.expectApproxEqAbs(@as(f32, 30), new[3].x, 1e-4);
    var pairs: [max_chars]i16 = undefined;
    var taken: [max_chars]bool = undefined;
    pair("Photos", old, "Photo 12", new, &pairs, &taken);
    try std.testing.expectEqualSlices(i16, &.{ 0, 1, 2, 3, 4, -1, -1, -1 }, pairs[0..8]);
    try std.testing.expect(!taken[5]);
    // Letters rearranged move to the nearest left over.
    const from = layout("abc", &a, {}, testWidth).?;
    const to = layout("cab", &b, {}, testWidth).?;
    pair("abc", from, "cab", to, &pairs, &taken);
    try std.testing.expectEqualSlices(i16, &.{ 2, 0, 1 }, pairs[0..3]);
    // Characters of several bytes pair whole.
    const cjk = layout("你好", &a, {}, testWidth).?;
    const cjk2 = layout("好你", &b, {}, testWidth).?;
    pair("你好", cjk, "好你", cjk2, &pairs, &taken);
    try std.testing.expectEqualSlices(i16, &.{ 1, 0 }, pairs[0..2]);
    var short: [2]Char = undefined;
    try std.testing.expect(layout("abc", &short, {}, testWidth) == null);
}
