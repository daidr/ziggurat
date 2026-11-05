//! Shared elements: a node whose `Style.match` names an identity that
//! another node showed in the frame before comes from there. It moves from
//! that one's box to its own, its content scaled on the way, and from that
//! one's look to its own: background, border and text colors, corners,
//! opacity and pose, each turn of the pose the short way round. With `fly`,
//! it paints over the rest of its layer (the window's content, or the
//! overlay it is in) out of the clips and opacity of the nodes around it,
//! and the other goes with it and fades out over the second half while the
//! one coming is opaque by half the way, as a crossfade between the two:
//! the other itself while it is still built, as in a page going away, or
//! else a copy of it as it showed last. Removed on its way with the nodes
//! around it, a flying node flies on as its copy, fading out by the end of
//! the way. With `morph`, a text node moves the characters its text shares
//! with the other's, or with its own as it changes in place, and fades the
//! others (`morph.zig`).
//!
//! Matching runs once per frame, after layout and before paint, on the
//! arranged boxes: it moves what is drawn, not the layout, so hit testing,
//! focus and semantics keep the arranged box, as `Style.pose` does. Moving
//! the content needs `Host.prepareShaderEffects`; without it the element
//! appears in place.
const std = @import("std");
const ui = @import("ziggurat_ui");
const animation = @import("ziggurat_animation");
const morph_text = @import("morph.zig");

const Pose = ui.effects.Pose;
const Font = ui.Font;
const Rect = ui.Rect;

pub const Match = struct {
    /// The identity the node shares with another, nonzero and the
    /// application's own, such as a photo's ID for its thumbnail and for
    /// the photo in its detail view. Give one node a key at a time, but the
    /// one going away while the other flies in.
    key: u64,
    motion: animation.Motion = .{ .tween = .{ .duration_ns = 300 * std.time.ns_per_ms, .easing = .cubic_out } },
    /// Fly over the rest of the window's content, or of the overlay it is
    /// in, out of the clips and opacity of the nodes around it, and
    /// crossfade with the other: the other itself while it is still
    /// built, or else a copy of it as it showed last. Gone on its way with
    /// the nodes around it, it flies on as a copy, fading out by the end.
    fly: bool = false,
    /// On a text node: move the characters its text shares with the
    /// other's from where they were to where they are, growing or
    /// shrinking to their size, and fade the others, as the text changes
    /// in place too; see `morph.zig`. An embedded leaf that lists its
    /// characters (`Embed.glyphs`), as a rich text, morphs them each in
    /// its own font and color.
    morph: bool = false,
    /// Mix the colors on the way in Oklab rather than in sRGB: between two
    /// saturated colors the way keeps their lightness and saturation
    /// instead of going through a dull, darker middle; see
    /// `ui.Color.mixOklab`.
    oklab: bool = false,
};

/// The identities a View follows at once; more are shown in place.
pub const capacity = 32;

/// What a matched node looks like where it shows.
pub const Look = struct {
    bounds: Rect,
    pose: Pose = .{},
    opacity: f32 = 1,
    background: ?u32 = null,
    border: ?u32 = null,
    color: ?u32 = null,
    radius: f32 = 0,

    /// The look `t` of the way from `a` to `b`. Colors missing on one side
    /// take the other's, so a fill appears or goes at once.
    pub fn mix(a: Look, b: Look, t: f32) Look {
        return mixIn(a, b, t, false);
    }
    /// `mix`, with the colors mixed in Oklab when `oklab`.
    pub fn mixIn(a: Look, b: Look, t: f32, oklab: bool) Look {
        if (oklab) {
            var result = mixIn(a, b, t, false);
            result.background = mixColorOklab(a.background, b.background, t);
            result.border = mixColorOklab(a.border, b.border, t);
            result.color = mixColorOklab(a.color, b.color, t);
            return result;
        }
        return .{
            .bounds = .{ .x = lerp(a.bounds.x, b.bounds.x, t), .y = lerp(a.bounds.y, b.bounds.y, t), .width = lerp(a.bounds.width, b.bounds.width, t), .height = lerp(a.bounds.height, b.bounds.height, t) },
            .pose = mixPose(a.pose, b.pose, t),
            .opacity = lerp(a.opacity, b.opacity, t),
            .background = mixColor(a.background, b.background, t),
            .border = mixColor(a.border, b.border, t),
            .color = mixColor(a.color, b.color, t),
            .radius = lerp(a.radius, b.radius, t),
        };
    }
};

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
/// An angle `t` of the way from `a` to `b` degrees, turning the short way.
pub fn turn(a: f32, b: f32, t: f32) f32 {
    var delta = @mod(b - a, 360);
    if (delta > 180) delta -= 360;
    return b - delta * (1 - t);
}
/// `Pose.mix` with each rotation the short way round, so that a turn from
/// 350 to 10 degrees goes through 0 rather than back through 180.
pub fn mixPose(a: Pose, b: Pose, t: f32) Pose {
    var result = Pose.mix(a, b, t);
    result.rotate = turn(a.rotate, b.rotate, t);
    result.rotate_x = turn(a.rotate_x, b.rotate_x, t);
    result.rotate_y = turn(a.rotate_y, b.rotate_y, t);
    return result;
}
/// An RGB color `t` of the way from `a` to `b`.
pub fn mixRgb(a: u32, b: u32, t: f32) u32 {
    return mixColor(a, b, t).?;
}
/// An RGB color `t` of the way from `a` to `b`, mixed in Oklab.
pub fn mixRgbOklab(a: u32, b: u32, t: f32) u32 {
    return ui.Color.mixOklab(.rgb(a), .rgb(b), t).hex();
}
fn mixColorOklab(a: ?u32, b: ?u32, t: f32) ?u32 {
    const from = a orelse return b;
    const to = b orelse return a;
    return mixRgbOklab(from, to, t);
}
fn mixColor(a: ?u32, b: ?u32, t: f32) ?u32 {
    const from = a orelse return b;
    const to = b orelse return a;
    var result: u32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |shift| {
        const x: f32 = @floatFromInt((from >> shift) & 0xff);
        const y: f32 = @floatFromInt((to >> shift) & 0xff);
        const value: u32 = @intFromFloat(@round(std.math.clamp(lerp(x, y, t), 0, 255)));
        result |= value << shift;
    }
    return result;
}
/// The pose that draws a node arranged at `arranged` within `look.bounds`,
/// turned as `look.pose` turns it.
pub fn poseFor(arranged: Rect, look: Look) Pose {
    var pose = look.pose;
    const width = @max(arranged.width, 1e-3);
    const height = @max(arranged.height, 1e-3);
    // About the box's center: the pose's own origin is kept for its turns
    // only where the boxes agree, which is where flights end.
    pose.origin = .{ 0.5, 0.5 };
    pose.x += (look.bounds.x + look.bounds.width / 2) - (arranged.x + arranged.width / 2);
    pose.y += (look.bounds.y + look.bounds.height / 2) - (arranged.y + arranged.height / 2);
    pose.scale_x *= look.bounds.width / width;
    pose.scale_y *= look.bounds.height / height;
    return pose;
}

/// Bytes of a text node's text a matched node keeps for `Match.morph`.
pub const max_text = 256;
/// Nodes and bytes of text a copy keeps of a flying node's subtree.
pub const copy_nodes = 32;
pub const copy_text = 512;
/// Flying nodes kept as copies at once.
pub const max_copies = 8;
/// Leaves of several styles whose characters a View keeps at once for
/// `Match.morph`; more change in place.
pub const max_glyph_texts = 4;

/// The characters an embedded leaf drew, kept for its morph.
pub const GlyphText = struct {
    key: u64 = 0,
    glyphs: [morph_text.max_chars]morph_text.Glyph = undefined,
    len: u8 = 0,
    /// Whether it drew more than morph: it crossfades.
    long: bool = false,

    pub fn items(self: *const GlyphText) []const morph_text.Glyph {
        return self.glyphs[0..self.len];
    }
};

/// A morph of an embedded leaf's characters to paint: they go from
/// `from`, written in `bounds`, to where the leaf writes them now, `t` of
/// the way.
pub const GlyphMorph = struct {
    from: *const GlyphText,
    bounds: Rect,
    t: f32,
};

/// The characters an embedded leaf `node` draws, into `out`; null when it
/// lists none.
fn glyphsOf(node: anytype, out: *GlyphText) bool {
    if (node.kind != .embed) return false;
    const content = node.embed orelse return false;
    const list = content.glyphs orelse return false;
    if (list(content.context, &out.glyphs)) |count| {
        out.len = @intCast(count);
        out.long = false;
    } else {
        out.len = 0;
        out.long = true;
    }
    return true;
}

/// `left` is the node a flight to `id` came from, which, still built as a
/// page going away, never flies back. A text node keeps its text and font
/// for `Match.morph`.
const Shown = struct {
    key: u64,
    id: u64,
    look: Look,
    left: u64 = 0,
    text: [max_text]u8 = undefined,
    text_len: u16 = 0,
    is_text: bool = false,
    /// An embedded leaf listing its characters, kept in `glyph_shown`.
    is_glyphs: bool = false,
    font: ?Font = null,
};

/// Where a morphing text comes from: the text, its font and its color, in
/// the box it showed in.
pub const MorphSource = struct {
    text: [max_text]u8 = undefined,
    text_len: u16 = 0,
    font: ?Font = null,
    color: ?u32 = null,
    bounds: Rect,
};

/// A morph to paint: the characters of the node's text go from where
/// those of `from` were, `t` of the way.
pub const Morph = struct {
    from: []const u8,
    font: ?Font,
    color: ?u32,
    bounds: Rect,
    t: f32,
};

const Flight = struct {
    key: u64,
    id: u64,
    /// The node it came from, while it is still built or kept as a copy;
    /// 0 for a text morphing in place.
    other: u64,
    from: Look,
    /// Its own look as of the last frame it was built.
    to: Look,
    fly: bool,
    oklab: bool = false,
    channel: animation.Channel,
    /// How far it had got when it went with the nodes around it, after
    /// which its copy flies on, fading out by the end of the way.
    gone: ?f32 = null,
    /// How far it is, as of the last frame.
    t: f32 = 0,
    morph: ?MorphSource = null,
    /// The characters of a leaf morphing come from, in `glyph_from`.
    glyphs: bool = false,
};

/// What a copy of a node keeps of each node of its subtree: its box and
/// how it fills, strokes and writes it, in colors resolved when it was
/// copied, since the themes and images of a build are not the copy's.
pub const CopyNode = struct {
    bounds: Rect,
    background: ?u32 = null,
    border: ?u32 = null,
    border_width: f32 = 1,
    radius: f32 = 0,
    color: u32 = 0,
    font: ?Font = null,
    text_start: u16 = 0,
    text_len: u16 = 0,
    opacity: f32 = 1,
    /// Nodes inside it, which its opacity and clip cover.
    end: u8 = 0,
    clip: bool = false,
};

/// A flying node as it was drawn the last frame it was built, painted in
/// its place once it is gone: as the node a flight leaves, going with it
/// and fading under it, or as the node flying in, which, gone with the
/// nodes around it, flies on.
pub const Copy = struct {
    id: u64 = 0,
    bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    nodes: [copy_nodes]CopyNode = undefined,
    len: u8 = 0,
    text: [copy_text]u8 = undefined,
    text_len: u16 = 0,
    /// Copied in the last frame: the node is still built.
    fresh: bool = false,

    pub fn textOf(self: *const Copy, node: CopyNode) []const u8 {
        return self.text[node.text_start..][0..node.text_len];
    }
};

/// A copy to paint this frame, under the nodes flying (`rank` 1, as the
/// one a flight leaves) or with them (`rank` 2, as the one flying in).
pub const CopyDraw = struct { copy: *const Copy, look: Look, rank: u8 };

/// Kept by the View from frame to frame.
/// The frame step while the display's refresh is unknown.
pub const default_frame_interval: u64 = 16 * std.time.ns_per_ms;

pub const State = struct {
    /// The time between frames of a flight: a refresh of the display.
    frame_interval: u64 = default_frame_interval,
    shown: [capacity]Shown = undefined,
    shown_len: usize = 0,
    flights: [capacity]Flight = undefined,
    flight_len: usize = 0,
    copies: [max_copies]Copy = @splat(.{}),
    draws: [2 * capacity]CopyDraw = undefined,
    draw_len: usize = 0,
    /// The characters of the leaves listing theirs as they showed, by
    /// match key, and those a morph of one comes from, by flight key.
    glyph_shown: [max_glyph_texts]GlyphText = @splat(.{}),
    glyph_from: [max_glyph_texts]GlyphText = @splat(.{}),

    /// Whether a flight is on its way.
    pub fn moving(self: *const State) bool {
        return self.flight_len != 0;
    }
    /// The copies to paint this frame, in the order to paint them.
    pub fn copyDraws(self: *const State) []const CopyDraw {
        return self.draws[0..self.draw_len];
    }
    /// The morph of text node `id` on its way, if it morphs.
    pub fn morphOf(self: *const State, id: u64) ?Morph {
        for (self.flights[0..self.flight_len]) |*entry| if (entry.id == id and entry.gone == null) {
            const source = &(entry.morph orelse return null);
            return .{ .from = source.text[0..source.text_len], .font = source.font, .color = source.color, .bounds = source.bounds, .t = entry.t };
        };
        return null;
    }
    /// The morph of the characters of embedded leaf `id` on its way, if
    /// it morphs.
    pub fn glyphMorphOf(self: *const State, id: u64) ?GlyphMorph {
        for (self.flights[0..self.flight_len]) |*entry| if (entry.id == id and entry.gone == null and entry.glyphs) {
            const from = glyphSlot(&self.glyph_from, entry.key) orelse return null;
            return .{ .from = from, .bounds = entry.from.bounds, .t = entry.t };
        };
        return null;
    }
    fn glyphSlot(list: anytype, key: u64) ?@TypeOf(&list[0]) {
        for (list) |*entry| if (entry.key == key) return entry;
        return null;
    }
    /// A slot of `list` for `key`: its own, or one no flight or shown key
    /// holds.
    fn glyphFree(self: *const State, list: *[max_glyph_texts]GlyphText, key: u64, from: bool) ?*GlyphText {
        if (glyphSlot(list, key)) |slot| return slot;
        for (list) |*entry| {
            const held = if (entry.key == 0) false else if (from) self.flightOf(entry.key) != null else self.shownOf(entry.key);
            if (!held) return entry;
        }
        return null;
    }
    fn flightOf(self: *const State, key: u64) ?*const Flight {
        for (self.flights[0..self.flight_len]) |*entry| if (entry.key == key) return entry;
        return null;
    }
    fn shownOf(self: *const State, key: u64) bool {
        for (self.shown[0..self.shown_len]) |entry| if (entry.key == key and entry.is_glyphs) return true;
        return false;
    }
    fn previous(self: *const State, key: u64) ?*const Shown {
        for (self.shown[0..self.shown_len]) |*entry| if (entry.key == key) return entry;
        return null;
    }
    fn flight(self: *State, key: u64) ?*Flight {
        for (self.flights[0..self.flight_len]) |*entry| if (entry.key == key) return entry;
        return null;
    }
    fn drop(self: *State, index: usize) void {
        self.flight_len -= 1;
        self.flights[index] = self.flights[self.flight_len];
    }
    fn copyOf(self: *const State, id: u64) ?*const Copy {
        if (id == 0) return null;
        for (&self.copies) |*entry| if (entry.id == id) return entry;
        return null;
    }
    fn draw(self: *State, copy: *const Copy, look: Look, rank: u8) void {
        if (self.draw_len == self.draws.len or look.opacity <= 0) return;
        self.draws[self.draw_len] = .{ .copy = copy, .look = look, .rank = rank };
        self.draw_len += 1;
    }

    /// Start, move and end the flights of the arranged `nodes` at `now`,
    /// rewriting the style of those on their way, and remember how each
    /// matched node shows for the next frame. Returns the next deadline a
    /// frame is due, if a flight is still on its way.
    pub fn apply(self: *State, nodes: anytype, now: u64, reduce_motion: bool) ?u64 {
        self.draw_len = 0;
        // Start a flight for each key a node newly shows: one another node
        // showed in the frame before, or a text morphing in place.
        for (nodes) |*node| {
            const match = node.style.match orelse continue;
            if (match.key == 0 or node.style.hidden) continue;
            const before = self.previous(match.key) orelse continue;
            const in_place = before.id == node.id;
            // A leaf listing its characters morphs them from those it, or
            // the other, showed.
            var current_glyphs: GlyphText = .{};
            const glyph_morph = match.morph and before.is_glyphs and glyphsOf(node, &current_glyphs);
            if (in_place) {
                // The same node: only its text changing moves anything.
                const text_changed = match.morph and before.is_text and node.kind == .text and !std.mem.eql(u8, before.text[0..before.text_len], clipped(node.text));
                const glyphs_changed = glyph_morph and if (glyphSlot(&self.glyph_shown, match.key)) |kept| kept.long != current_glyphs.long or !morph_text.sameGlyphs(kept.items(), current_glyphs.items()) else false;
                if (!text_changed and !glyphs_changed) continue;
            } else {
                if (before.left == node.id) continue;
                // The one in flight, and the one it left, which goes with it.
                if (self.flight(match.key)) |current| if (current.id == node.id or current.other == node.id) continue;
            }
            // The one that showed it in the frame before is going away;
            // under reduced motion the other is in place at once.
            if (reduce_motion) {
                if (self.flight(match.key)) |current| self.drop(current - &self.flights);
                continue;
            }
            var channel = animation.Channel.init(0) catch continue;
            channel.retarget(now, 1, .{ .motion = match.motion }) catch continue;
            var value: Flight = .{ .key = match.key, .id = node.id, .other = if (in_place) 0 else before.id, .from = before.look, .to = lookOf(node), .fly = match.fly and !in_place, .oklab = match.oklab, .channel = channel };
            if (match.morph and node.kind == .text and before.is_text) {
                value.morph = .{ .bounds = before.look.bounds, .font = before.font, .color = before.look.color, .text_len = before.text_len };
                @memcpy(value.morph.?.text[0..before.text_len], before.text[0..before.text_len]);
            }
            if (glyph_morph) if (glyphSlot(&self.glyph_shown, match.key)) |kept| if (self.glyphFree(&self.glyph_from, match.key, true)) |slot| {
                slot.* = kept.*;
                value.glyphs = true;
                // Its own box holds its characters, which move instead.
                value.morph = .{ .bounds = before.look.bounds };
            };
            if (self.flight(match.key)) |current| {
                current.* = value;
            } else if (self.flight_len < capacity) {
                self.flights[self.flight_len] = value;
                self.flight_len += 1;
            }
        }
        // Move each flight. One whose node is gone ends, unless it flies:
        // then its copy flies on, fading out by the end of the way.
        var drawn: [2 * capacity]struct { id: u64, look: Look } = undefined;
        var drawn_len: usize = 0;
        var wake: ?u64 = null;
        var index: usize = 0;
        while (index < self.flight_len) {
            const current = &self.flights[index];
            const target = for (nodes) |*node| {
                if (node.id == current.id) if (node.style.match) |match| if (match.key == current.key and !node.style.hidden) break node;
            } else null;
            const copy = if (target == null and current.fly) self.copyOf(current.id) else null;
            if (target == null and copy == null) {
                self.drop(index);
                continue;
            }
            const sample = current.channel.advance(now) catch {
                self.drop(index);
                continue;
            };
            const t: f32 = @floatCast(sample.value);
            current.t = t;
            if (target) |node| current.to = lookOf(node);
            const to = current.to;
            var look = Look.mixIn(current.from, to, t, current.oklab);
            if (target == null) {
                const at = current.gone orelse t;
                current.gone = at;
                look.opacity = to.opacity * (if (at >= 1) 0 else std.math.clamp((1 - t) / (1 - at), 0, 1));
            }
            // The node it left goes with it: itself while built, or else
            // its copy. A text morphing moves the other's characters
            // instead.
            var departing: @TypeOf(target) = null;
            var departing_copy: ?*const Copy = null;
            if (current.fly and current.other != 0) {
                departing = for (nodes) |*other| {
                    if (other.id == current.other and !other.style.hidden) break other;
                } else null;
                if (departing == null) departing_copy = self.copyOf(current.other);
            }
            if (departing != null or departing_copy != null) {
                // The one coming is opaque by half the way; the other goes
                // with it and fades over the second half.
                if (current.morph == null) look.opacity *= @min(1, 2 * t);
                var with = look;
                with.opacity = if (current.morph != null) 0 else current.from.opacity * (1 - std.math.clamp(2 * t - 1, 0, 1));
                if (departing) |other| {
                    const fading = lookOf(other);
                    with.opacity = if (current.morph != null) 0 else fading.opacity * (1 - std.math.clamp(2 * t - 1, 0, 1));
                    with.background = fading.background;
                    with.border = fading.border;
                    with.color = fading.color;
                    setLook(other, with, 1, false);
                    drawn[drawn_len] = .{ .id = other.id, .look = with };
                    drawn_len += 1;
                }
                if (departing_copy) |kept| if (with.opacity > 0) self.draw(kept, with, 1);
            }
            if (target) |node| {
                setLook(node, look, if (current.fly) 2 else 0, current.morph != null);
                drawn[drawn_len] = .{ .id = node.id, .look = look };
                drawn_len += 1;
            } else self.draw(copy.?, look, 2);
            if (current.channel.run == null) {
                self.drop(index);
                continue;
            }
            if (current.channel.nextWake(now, self.frame_interval) catch null) |deadline| wake = if (wake) |w| @min(w, deadline) else deadline;
            index += 1;
        }
        // Remember how each matched node shows, the one flying in over the
        // one it came from.
        const before = self.shown;
        const before_len = self.shown_len;
        var count: usize = 0;
        for (nodes) |*node| {
            const match = node.style.match orelse continue;
            if (match.key == 0 or node.style.hidden) continue;
            const look = for (drawn[0..drawn_len]) |entry| {
                if (entry.id == node.id) break entry.look;
            } else lookOf(node);
            // Forget the one a flight left once it is no longer built, so
            // that, built again, it comes back from here.
            const carried = if (self.flight(match.key)) |current| current.other else for (before[0..before_len]) |old| {
                if (old.key == match.key and old.id == node.id) break old.left;
            } else 0;
            const left = for (nodes) |*other| {
                if (carried != 0 and other.id == carried) break carried;
            } else 0;
            var shown: Shown = .{ .key = match.key, .id = node.id, .look = look, .left = left };
            if (node.kind == .text) {
                const text = clipped(node.text);
                shown.is_text = true;
                shown.text_len = @intCast(text.len);
                @memcpy(shown.text[0..text.len], text);
                shown.font = node.style.font;
            } else if (match.morph) {
                var glyphs: GlyphText = .{};
                if (glyphsOf(node, &glyphs)) if (self.glyphFree(&self.glyph_shown, match.key, false)) |slot| {
                    glyphs.key = match.key;
                    slot.* = glyphs;
                    shown.is_glyphs = true;
                };
            }
            const existing = for (self.shown[0..count]) |*entry| {
                if (entry.key == match.key) break entry;
            } else null;
            if (existing) |entry| {
                // A key two nodes share: keep the one a flight brings in, or
                // the one that held it, so the one going away never flies
                // back.
                const keep = if (self.flight(match.key)) |current| current.id else for (before[0..before_len]) |old| {
                    if (old.key == match.key) break old.id;
                } else entry.id;
                if (node.id == keep) entry.* = shown;
            } else if (count < capacity) {
                self.shown[count] = shown;
                count += 1;
            }
        }
        self.shown_len = count;
        return wake;
    }

    /// Copy each flying node of the arranged `nodes`, as drawn, for when it
    /// is gone, and forget the copies of nodes neither built nor on a
    /// flight. `resolve(node)` is the color a text node writes in. Call it
    /// after `apply`.
    pub fn keepCopies(self: *State, nodes: anytype, context: anytype, resolve: fn (@TypeOf(context), *const @TypeOf(nodes[0])) u32) void {
        for (&self.copies) |*entry| entry.fresh = false;
        for (nodes, 0..) |*node, at| {
            const match = node.style.match orelse continue;
            if (match.key == 0 or !match.fly or node.style.hidden) continue;
            const slot = for (&self.copies) |*entry| {
                if (entry.id == node.id) break entry;
            } else for (&self.copies) |*entry| {
                if (entry.id == 0 or (!entry.fresh and !self.used(entry.id))) break entry;
            } else continue;
            slot.* = .{ .id = node.id, .bounds = node.bounds, .fresh = true };
            capture(slot, nodes, at, context, resolve);
        }
        for (&self.copies) |*entry| if (entry.id != 0 and !entry.fresh and !self.used(entry.id)) {
            entry.id = 0;
        };
    }
    /// Whether a flight flies node `id` or leaves it.
    fn used(self: *const State, id: u64) bool {
        for (self.flights[0..self.flight_len]) |entry| if (entry.id == id or entry.other == id) return true;
        return false;
    }
};

/// Copy the subtree of `nodes[root]` into `copy`, as far as it holds: the
/// boxes, fills, strokes and texts, under the opacity and clips of the
/// containers inside it. The root's own pose and opacity are the look's.
fn capture(copy: *Copy, nodes: anytype, root: usize, context: anytype, resolve: anytype) void {
    const stop = nodes[root].end;
    var at = root;
    var depth_stack: [copy_nodes]struct { end: u32, slot: u8 } = undefined;
    var depth: usize = 0;
    while (at < stop) {
        const node = &nodes[at];
        while (depth > 0 and depth_stack[depth - 1].end <= at) {
            depth -= 1;
            copy.nodes[depth_stack[depth].slot].end = copy.len;
        }
        if (node.concealed or node.floats() or copy.len == copy_nodes) {
            at = if (node.isContainer()) node.end else at + 1;
            continue;
        }
        const style = node.style;
        var entry: CopyNode = .{ .bounds = node.bounds, .radius = style.radius, .border_width = style.border_width, .opacity = if (at == root) 1 else style.opacity };
        if (node.isContainer()) {
            entry.background = style.background;
            entry.border = style.border;
            entry.clip = at != root and node.clips();
        } else if (node.kind == .text and node.text.len > 0) {
            const room = copy_text - copy.text_len;
            const text = clipped(node.text);
            const length = @min(text.len, room);
            @memcpy(copy.text[copy.text_len..][0..length], text[0..length]);
            entry.text_start = copy.text_len;
            entry.text_len = @intCast(length);
            copy.text_len += @intCast(length);
            entry.font = style.font;
            entry.color = resolve(context, node);
        } else {
            entry.background = style.background;
        }
        const slot = copy.len;
        copy.nodes[slot] = entry;
        copy.len += 1;
        if (node.isContainer() and node.end > at + 1) {
            depth_stack[depth] = .{ .end = node.end, .slot = slot };
            depth += 1;
            at += 1;
        } else {
            copy.nodes[slot].end = copy.len;
            at = if (node.isContainer()) node.end else at + 1;
        }
    }
    while (depth > 0) {
        depth -= 1;
        copy.nodes[depth_stack[depth].slot].end = copy.len;
    }
}

/// A text as far as a matched node keeps it, cut at a character.
fn clipped(text: []const u8) []const u8 {
    if (text.len <= max_text) return text;
    var end: usize = max_text;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

/// How a node looks at rest, in its arranged box.
fn lookOf(node: anytype) Look {
    const style = node.style;
    return .{ .bounds = node.bounds, .pose = style.pose orelse .{}, .opacity = style.opacity, .background = style.background, .border = style.border, .color = style.color, .radius = style.radius };
}
/// Show `node` with `look`, painted over the rest of its layer when it
/// flies (`rank` 1 under `rank` 2), and, morphing, in its own box, where
/// the paint moves its characters instead.
fn setLook(node: anytype, look: Look, rank: u8, morphing: bool) void {
    const pose = poseFor(node.bounds, look);
    node.style.pose = if (morphing or pose.isIdentity()) null else pose;
    node.style.opacity = std.math.clamp(look.opacity, 0, 1);
    node.style.background = look.background;
    node.style.border = look.border;
    node.style.color = look.color;
    node.style.radius = @max(0, look.radius);
    node.lifted = rank;
}

test "turns go the short way round" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), @mod(turn(350, 10, 0.5), 360), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10), turn(350, 10, 1), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 90), turn(0, 180, 0.5), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 45), mixPose(.{ .rotate_y = 0 }, .{ .rotate_y = 90 }, 0.5).rotate_y, 1e-4);
}

test "a pose draws the arranged box where the look is" {
    const pose = poseFor(.{ .x = 100, .y = 100, .width = 200, .height = 100 }, .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 } });
    try std.testing.expectApproxEqAbs(@as(f32, -150), pose.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -125), pose.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pose.scale_x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pose.scale_y, 1e-4);
    try std.testing.expectEqual(@as(?u32, 0x808080), mixColor(0x000000, 0xffffff, 0.5));
    try std.testing.expectEqual(@as(?u32, 0xffffff), mixColor(null, 0xffffff, 0.5));
}
