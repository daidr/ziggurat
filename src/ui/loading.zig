//! Loading indicators drawn procedurally from a phase the caller derives from
//! its own clock. Nothing here keeps time, schedules frames or allocates; an
//! indicator that is not drawn costs nothing. Like backdrop effects they are
//! rasterized on the software planes, so a frame holding one replays in
//! software.
const std = @import("std");
const layout = @import("layout.zig");
const geometry = @import("geometry.zig");
const cpu = @import("cpu_gradient.zig");
const composite = @import("composite.zig");
pub const Rect = layout.Rect;
pub const Color = geometry.Color;

pub const max_entries = 16;
/// Height of an indicator in DIP when none is given; width follows its aspect.
pub const default_size: f32 = 20;

pub const Kind = enum(u8) {
    arc,
    atom,
    blocks,
    bouncing_dots,
    cascade,
    circular_dots,
    classic,
    classic_v2,
    clock,
    comet,
    compass,
    dual,
    eclipse,
    flip,
    gather,
    leap,
    linear_dots,
    loading,
    morph,
    orbit,
    pulse,
    radar,
    ring,
    ripple,
    slide,
    snake,
    swirl,
    trace,
    wave,

    /// Display name, for galleries and pickers.
    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .arc => "Arc",
            .atom => "Atom",
            .blocks => "Blocks",
            .bouncing_dots => "Bouncing dots",
            .cascade => "Cascade",
            .circular_dots => "Circular dots",
            .classic => "Classic",
            .classic_v2 => "Classic v2",
            .clock => "Clock",
            .comet => "Comet",
            .compass => "Compass",
            .dual => "Dual",
            .eclipse => "Eclipse",
            .flip => "Flip",
            .gather => "Gather",
            .leap => "Leap",
            .linear_dots => "Linear dots",
            .loading => "Loading",
            .morph => "Morph",
            .orbit => "Orbit",
            .pulse => "Pulse",
            .radar => "Radar",
            .ring => "Ring",
            .ripple => "Ripple",
            .slide => "Slide",
            .snake => "Snake",
            .swirl => "Swirl",
            .trace => "Trace",
            .wave => "Wave",
        };
    }
    /// One cycle of the indicator's animation.
    pub fn cycle(self: Kind) u64 {
        const ms: u64 = switch (self) {
            .arc, .circular_dots, .classic_v2, .ring => 800,
            .atom, .dual, .loading => 1000,
            .blocks => 1300,
            .bouncing_dots, .compass => 500,
            .cascade, .radar => 1500,
            .classic, .clock, .eclipse, .flip, .morph, .pulse, .ripple, .swirl, .trace => 1200,
            .comet => 700,
            .gather => 1600,
            .leap => 1800,
            .linear_dots, .wave => 900,
            .orbit => 750,
            .slide => 2400,
            .snake => 1400,
        };
        return ms * std.time.ns_per_ms;
    }
    /// Width over height; the dot rows are wider than they are tall.
    pub fn aspect(self: Kind) f32 {
        return switch (self) {
            .bouncing_dots, .linear_dots => 2,
            else => 1,
        };
    }
    /// Whether `Options.easing` applies.
    pub fn turns(self: Kind) bool {
        return switch (self) {
            .arc, .atom, .clock, .comet, .dual, .orbit, .radar, .ring, .snake, .trace => true,
            else => false,
        };
    }
};
pub const all = std.enums.values(Kind);

pub const Easing = enum(u8) {
    linear,
    ease_in_out,
    /// Two eased half turns per cycle, pausing between them.
    stacked,
};
pub const Cap = enum(u8) { round, flat };
pub const Sweep = enum(u8) { diagonal, rows, columns };
pub const RippleDirection = enum(u8) { out, in };
pub const WaveOrigin = enum(u8) { center, bottom };
/// Variations; each applies only to the indicators its comment names.
pub const Options = struct {
    /// Arc, Atom, Clock, Comet, Dual, Orbit, Radar, Ring, Snake, Trace.
    easing: Easing = .linear,
    /// Arc, Cascade, Dual, Ring, Snake, Trace.
    cap: Cap = .round,
    /// Blocks.
    sweep: Sweep = .diagonal,
    /// Ripple.
    direction: RippleDirection = .out,
    /// Wave.
    origin: WaveOrigin = .center,
};

/// Cycles completed after `elapsed` nanoseconds of a cycle `duration` long;
/// zero duration uses the indicator's own.
pub fn phase(kind: Kind, elapsed: u64, duration: u64) f64 {
    const length = if (duration == 0) kind.cycle() else duration;
    return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(length));
}

/// One recorded indicator in absolute DIP.
pub const Entry = struct {
    bounds: Rect,
    kind: Kind,
    /// Cycles completed; the fractional part is the pose.
    phase: f64,
    color: Color,
    options: Options = .{},
};

/// The view box an indicator is designed in: `24 * aspect` by 24 units.
const unit: f64 = 24;

const Shape = union(enum) {
    disc: struct { x: f64, y: f64, r: f64 },
    ring: struct { x: f64, y: f64, r: f64, w: f64 },
    /// Clockwise from `start` (radians from +x, y down) through `sweep`.
    /// With `fade`, alpha rises from 0 at the tail to 1 at the head.
    arc: struct { x: f64, y: f64, r: f64, w: f64, start: f64, sweep: f64, cap: Cap, fade: bool = false },
    box: struct { x: f64, y: f64, hw: f64, hh: f64, radius: f64, angle: f64 = 0 },
    capsule: struct { x0: f64, y0: f64, x1: f64, y1: f64, w: f64, cap: Cap = .round },
    ellipse: struct { x: f64, y: f64, rx: f64, ry: f64, w: f64, angle: f64 },
    /// A disc whose alpha fades from the leading edge `angle` back through `sweep`.
    sector: struct { x: f64, y: f64, r: f64, angle: f64, sweep: f64 },
};
const Element = struct { shape: Shape, alpha: f64 = 1 };
const max_elements = 40;
const Scene = struct {
    elements: [max_elements]Element = undefined,
    len: usize = 0,
    width: f64 = unit,
    fn add(self: *Scene, shape: Shape, alpha: f64) void {
        if (self.len == max_elements or alpha <= 0) return;
        self.elements[self.len] = .{ .shape = shape, .alpha = @min(alpha, 1) };
        self.len += 1;
    }
};

fn frac(value: f64) f64 {
    return value - @floor(value);
}
fn ease(value: f64) f64 {
    return 0.5 - 0.5 * @cos(pi * value);
}
fn turn(t: f64, easing: Easing) f64 {
    return switch (easing) {
        .linear => t,
        .ease_in_out => ease(t),
        .stacked => if (t < 0.5) ease(t * 2) / 2 else 0.5 + ease(t * 2 - 1) / 2,
    };
}
const pi: f64 = std.math.pi;
const tau: f64 = 2 * pi;
/// Opacity of element `i` of `n` in a chasing ring: the lead is opaque and
/// the trail fades.
fn chase(t: f64, i: usize, n: usize) f64 {
    const k = frac(t - @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)));
    return 0.15 + 0.85 * (1 - k);
}

fn scene(entry: Entry) Scene {
    var s: Scene = .{ .width = unit * entry.kind.aspect() };
    const t = frac(entry.phase);
    const o = entry.options;
    const cx: f64 = 12;
    const cy: f64 = 12;
    switch (entry.kind) {
        .arc => s.add(.{ .arc = .{ .x = cx, .y = cy, .r = 9, .w = 2.5, .start = tau * turn(t, o.easing) - pi / 2, .sweep = tau * 0.75, .cap = o.cap } }, 1),
        .atom => {
            s.add(.{ .disc = .{ .x = cx, .y = cy, .r = 2.2 } }, 1);
            const spin = turn(t, o.easing);
            for (0..3) |i| {
                const k = spin + @as(f64, @floatFromInt(i)) / 3;
                s.add(.{ .ellipse = .{ .x = cx, .y = cy, .rx = 10, .ry = 3 + 1.8 * @sin(tau * k), .w = 1.3, .angle = pi * (@as(f64, @floatFromInt(i)) / 3 + spin / 2) } }, 1);
            }
        },
        .blocks => for (0..3) |row| for (0..3) |column| {
            const delay: f64 = switch (o.sweep) {
                .diagonal => @as(f64, @floatFromInt(row + column)) * 0.1,
                .rows => @as(f64, @floatFromInt(row)) * 0.15,
                .columns => @as(f64, @floatFromInt(column)) * 0.15,
            };
            const scale = 0.65 + 0.35 * @cos(tau * (t - delay));
            s.add(.{ .box = .{ .x = 5 + 7 * @as(f64, @floatFromInt(column)), .y = 5 + 7 * @as(f64, @floatFromInt(row)), .hw = 2.75 * scale, .hh = 2.75 * scale, .radius = 1.2 * scale } }, 1);
        },
        .bouncing_dots => for (0..3) |i| {
            const lift = @max(0, @sin(tau * (t - @as(f64, @floatFromInt(i)) * 0.16)));
            s.add(.{ .disc = .{ .x = 10 + 14 * @as(f64, @floatFromInt(i)), .y = 15 - 7 * lift, .r = 4 } }, 1);
        },
        .cascade => for (0..3) |i| {
            const k = ease(frac(t - @as(f64, @floatFromInt(i)) * 0.12));
            const fi: f64 = @floatFromInt(i);
            s.add(.{ .arc = .{ .x = cx, .y = cy, .r = 10 - 3 * fi, .w = 1.8, .start = tau * k - pi / 2, .sweep = tau * (0.25 + 0.12 * fi), .cap = o.cap } }, 1);
        },
        .circular_dots => for (0..8) |i| {
            const a = tau * @as(f64, @floatFromInt(i)) / 8 - pi / 2;
            s.add(.{ .disc = .{ .x = cx + 9 * @cos(a), .y = cy + 9 * @sin(a), .r = 2 } }, chase(t, i, 8));
        },
        .classic => for (0..12) |i| {
            const a = tau * @as(f64, @floatFromInt(i)) / 12 - pi / 2;
            s.add(.{ .capsule = .{ .x0 = cx + 5 * @cos(a), .y0 = cy + 5 * @sin(a), .x1 = cx + 10.5 * @cos(a), .y1 = cy + 10.5 * @sin(a), .w = 2 } }, chase(t, i, 12));
        },
        .classic_v2 => for (0..8) |i| {
            const a = tau * @as(f64, @floatFromInt(i)) / 8 - pi / 2;
            s.add(.{ .capsule = .{ .x0 = cx + 6 * @cos(a), .y0 = cy + 6 * @sin(a), .x1 = cx + 10 * @cos(a), .y1 = cy + 10 * @sin(a), .w = 2.5 } }, chase(t, i, 8));
        },
        .clock => {
            s.add(.{ .ring = .{ .x = cx, .y = cy, .r = 10, .w = 1.6 } }, 0.25);
            s.add(.{ .disc = .{ .x = cx, .y = cy, .r = 1.6 } }, 1);
            const a = tau * turn(t, o.easing) - pi / 2;
            s.add(.{ .capsule = .{ .x0 = cx, .y0 = cy, .x1 = cx + 7 * @cos(a), .y1 = cy + 7 * @sin(a), .w = 2 } }, 1);
        },
        .comet => {
            const head = tau * turn(t, o.easing) - pi / 2;
            s.add(.{ .arc = .{ .x = cx, .y = cy, .r = 9, .w = 2.5, .start = head - tau * 0.75, .sweep = tau * 0.75, .cap = .flat, .fade = true } }, 1);
            s.add(.{ .disc = .{ .x = cx + 9 * @cos(head), .y = cy + 9 * @sin(head), .r = 1.6 } }, 1);
        },
        .compass => {
            const base = pi / 2 * ease(t);
            for (0..4) |i| {
                const a = base + pi / 2 * @as(f64, @floatFromInt(i)) - pi / 2;
                s.add(.{ .capsule = .{ .x0 = cx + 4 * @cos(a), .y0 = cy + 4 * @sin(a), .x1 = cx + 10 * @cos(a), .y1 = cy + 10 * @sin(a), .w = 2.5 } }, 1);
            }
        },
        .dual => {
            const k = turn(t, o.easing);
            s.add(.{ .arc = .{ .x = cx, .y = cy, .r = 9.5, .w = 2.2, .start = tau * k - pi / 2, .sweep = tau * 0.4, .cap = o.cap } }, 1);
            s.add(.{ .arc = .{ .x = cx, .y = cy, .r = 5, .w = 2.2, .start = -tau * k + pi / 2, .sweep = tau * 0.4, .cap = o.cap } }, 1);
        },
        .eclipse => {
            const c = @cos(tau * t);
            const front = @sin(tau * t);
            const first: Shape = .{ .disc = .{ .x = cx - 6 * c, .y = cy, .r = 4 + 1.5 * front } };
            const second: Shape = .{ .disc = .{ .x = cx + 6 * c, .y = cy, .r = 4 - 1.5 * front } };
            // The nearer dot draws last and fully opaque.
            if (front >= 0) {
                s.add(second, 0.5);
                s.add(first, 1);
            } else {
                s.add(first, 0.5);
                s.add(second, 1);
            }
        },
        .flip => {
            const half = t < 0.5;
            const k = if (half) t * 2 else t * 2 - 1;
            const squash = @abs(@cos(pi * ease(k)));
            s.add(.{ .box = .{ .x = cx, .y = cy, .hw = if (half) 7 * squash else 7, .hh = if (half) 7 else 7 * squash, .radius = 2 * squash } }, 1);
        },
        .gather => {
            const spread = 3 + 3 * (0.5 + 0.5 * @cos(tau * t));
            const angle = pi / 2 * ease(t);
            for (0..4) |i| {
                const a = angle + pi / 2 * @as(f64, @floatFromInt(i)) + pi / 4;
                const d = spread * std.math.sqrt2;
                s.add(.{ .box = .{ .x = cx + d * @cos(a), .y = cy + d * @sin(a), .hw = 2.6, .hh = 2.6, .radius = 1, .angle = angle } }, 1);
            }
        },
        .leap => {
            const p = ease(t);
            s.add(.{ .disc = .{ .x = 5 + 7 * p, .y = cy, .r = 2.8 } }, 1);
            s.add(.{ .disc = .{ .x = 12 + 7 * p, .y = cy, .r = 2.8 } }, 1);
            s.add(.{ .disc = .{ .x = 19 - 14 * p, .y = cy - 8 * @sin(pi * p), .r = 2.8 } }, 1);
        },
        .linear_dots => for (0..3) |i| {
            const k = t - @as(f64, @floatFromInt(i)) / 3;
            s.add(.{ .disc = .{ .x = 10 + 14 * @as(f64, @floatFromInt(i)), .y = cy, .r = 4 } }, 0.25 + 0.75 * (0.5 + 0.5 * @cos(tau * k)));
        },
        .loading => for (0..8) |segment| {
            const a = tau * @as(f64, @floatFromInt(segment)) / 8 - pi / 2;
            const alpha = chase(t, segment, 8);
            for (0..4) |step| {
                const r = 4 + 2.1 * @as(f64, @floatFromInt(step));
                s.add(.{ .box = .{ .x = cx + r * @cos(a), .y = cy + r * @sin(a), .hw = 0.85, .hh = 0.85, .radius = 0, .angle = a } }, alpha);
            }
        },
        .morph => {
            const round = 0.5 - 0.5 * @cos(tau * t);
            s.add(.{ .box = .{ .x = cx, .y = cy, .hw = 7, .hh = 7, .radius = 2 + 5 * round, .angle = pi * ease(t) } }, 1);
        },
        .orbit => {
            s.add(.{ .disc = .{ .x = cx, .y = cy, .r = 2.5 } }, 1);
            s.add(.{ .arc = .{ .x = cx, .y = cy, .r = 9, .w = 2, .start = tau * turn(t, o.easing) - pi / 2, .sweep = pi, .cap = .round, .fade = true } }, 1);
        },
        .pulse => {
            s.add(.{ .disc = .{ .x = cx, .y = cy, .r = 3 } }, 1);
            s.add(.{ .ring = .{ .x = cx, .y = cy, .r = 3 + 7.5 * t, .w = 2 } }, 1 - t);
        },
        .radar => {
            s.add(.{ .disc = .{ .x = cx, .y = cy, .r = 10.5 } }, 0.12);
            s.add(.{ .ring = .{ .x = cx, .y = cy, .r = 10, .w = 1.4 } }, 0.5);
            s.add(.{ .sector = .{ .x = cx, .y = cy, .r = 10, .angle = tau * turn(t, o.easing) - pi / 2, .sweep = pi / 2 } }, 0.7);
            s.add(.{ .disc = .{ .x = cx, .y = cy, .r = 1.8 } }, 1);
        },
        .ring => {
            s.add(.{ .ring = .{ .x = cx, .y = cy, .r = 9, .w = 2.5 } }, 0.25);
            s.add(.{ .arc = .{ .x = cx, .y = cy, .r = 9, .w = 2.5, .start = tau * turn(t, o.easing) - pi / 2, .sweep = tau * 0.25, .cap = o.cap } }, 1);
        },
        .ripple => for (0..3) |i| {
            const k0 = frac(t + @as(f64, @floatFromInt(i)) / 3);
            const k = if (o.direction == .out) k0 else 1 - k0;
            s.add(.{ .ring = .{ .x = cx, .y = cy, .r = 2 + 8.5 * k, .w = 1.5 } }, 1 - k);
        },
        .slide => {
            const corners = [4][2]f64{ .{ 7, 7 }, .{ 17, 7 }, .{ 17, 17 }, .{ 7, 17 } };
            const steps = t * 4;
            const step: usize = @intFromFloat(@floor(steps));
            const k = ease(steps - @floor(steps));
            const empty = (4 - step % 4) % 4;
            const moving = (empty + 3) % 4;
            for (0..4) |corner| {
                if (corner == empty) continue;
                var p = corners[corner];
                if (corner == moving) p = .{ p[0] + (corners[empty][0] - p[0]) * k, p[1] + (corners[empty][1] - p[1]) * k };
                s.add(.{ .disc = .{ .x = p[0], .y = p[1], .r = 3.5 } }, 1);
            }
        },
        .snake => {
            const k = turn(t, o.easing);
            const length = 0.5 - 0.5 * @cos(tau * k);
            const start = tau * (1.5 * k) - tau * 0.6 * length - pi / 2;
            s.add(.{ .arc = .{ .x = cx, .y = cy, .r = 9, .w = 2.5, .start = start, .sweep = tau * (0.06 + 0.66 * length), .cap = o.cap } }, 1);
        },
        .swirl => {
            const order = [8][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 2, 1 }, .{ 2, 2 }, .{ 1, 2 }, .{ 0, 2 }, .{ 0, 1 } };
            for (order, 0..) |cell, i| s.add(.{ .box = .{ .x = 5 + 7 * @as(f64, @floatFromInt(cell[0])), .y = 5 + 7 * @as(f64, @floatFromInt(cell[1])), .hw = 2.6, .hh = 2.6, .radius = 1 } }, chase(t, i, 8));
        },
        // A faint outline and a dash a quarter of its length running along it.
        .trace => traceOutline(&s, turn(t, o.easing), o.cap),
        .wave => for (0..5) |i| {
            const fi: f64 = @floatFromInt(i);
            const delay = if (o.origin == .center) @abs(fi - 2) * 0.12 else fi * 0.1;
            const h = 4 + 12 * (0.5 + 0.5 * @sin(tau * (t - delay)));
            const x = 4 + 4 * fi;
            if (o.origin == .center) s.add(.{ .capsule = .{ .x0 = x, .y0 = cy - h / 2 + 1.25, .x1 = x, .y1 = cy + h / 2 - 1.25, .w = 2.5 } }, 1) else s.add(.{ .capsule = .{ .x0 = x, .y0 = 20.75 - h + 1.25, .x1 = x, .y1 = 20.75 - 1.25, .w = 2.5 } }, 1);
        },
    }
    return s;
}

/// Trace draws its square outline from straight sides and corner arcs so
/// the dash can follow the same path.
fn traceOutline(s: *Scene, head: f64, cap: Cap) void {
    const half: f64 = 9;
    const r: f64 = 4;
    const w: f64 = 1.6;
    const side = 2 * (half - r);
    const corner = pi * r / 2;
    const total = 4 * side + 4 * corner;
    // Segment k: side then corner, clockwise from the top-left corner's end.
    const Segment = struct { kind: enum { side, corner }, x0: f64, y0: f64, x1: f64, y1: f64, cx: f64 = 0, cy: f64 = 0, start: f64 = 0 };
    const c: f64 = 12;
    const segments = [8]Segment{
        .{ .kind = .side, .x0 = c - half + r, .y0 = c - half, .x1 = c + half - r, .y1 = c - half },
        .{ .kind = .corner, .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0, .cx = c + half - r, .cy = c - half + r, .start = -pi / 2 },
        .{ .kind = .side, .x0 = c + half, .y0 = c - half + r, .x1 = c + half, .y1 = c + half - r },
        .{ .kind = .corner, .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0, .cx = c + half - r, .cy = c + half - r, .start = 0 },
        .{ .kind = .side, .x0 = c + half - r, .y0 = c + half, .x1 = c - half + r, .y1 = c + half },
        .{ .kind = .corner, .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0, .cx = c - half + r, .cy = c + half - r, .start = pi / 2 },
        .{ .kind = .side, .x0 = c - half, .y0 = c + half - r, .x1 = c - half, .y1 = c - half + r },
        .{ .kind = .corner, .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0, .cx = c - half + r, .cy = c - half + r, .start = pi },
    };
    // Outline.
    for (segments) |segment| switch (segment.kind) {
        .side => s.add(.{ .capsule = .{ .x0 = segment.x0, .y0 = segment.y0, .x1 = segment.x1, .y1 = segment.y1, .w = w, .cap = .flat } }, 0.25),
        .corner => s.add(.{ .arc = .{ .x = segment.cx, .y = segment.cy, .r = r, .w = w, .start = segment.start, .sweep = pi / 2, .cap = .flat } }, 0.25),
    };
    // Dash from `head - length` to `head` along the path.
    const length = total * 0.25;
    var from = frac(head) * total - length;
    if (from < 0) from += total;
    var remaining = length;
    var position: f64 = 0;
    var index: usize = 0;
    var first = true;
    // Walk twice around at most to cover the wrap.
    while (remaining > 0 and index < 16) : (index += 1) {
        const segment = segments[index % 8];
        const span = if (segment.kind == .side) side else corner;
        const seg_start = position;
        const seg_end = position + span;
        position = seg_end;
        if (seg_end <= from) continue;
        const a = @max(from, seg_start) - seg_start;
        const b = @min(span, a + remaining);
        if (b <= a) continue;
        const dash_cap: Cap = if (first) cap else .flat;
        first = false;
        remaining -= b - a;
        const end_cap: Cap = if (remaining <= 0) cap else .flat;
        switch (segment.kind) {
            .side => {
                const dx = (segment.x1 - segment.x0) / span;
                const dy = (segment.y1 - segment.y0) / span;
                s.add(.{ .capsule = .{ .x0 = segment.x0 + dx * a, .y0 = segment.y0 + dy * a, .x1 = segment.x0 + dx * b, .y1 = segment.y0 + dy * b, .w = w, .cap = if (dash_cap == .round or end_cap == .round) .round else .flat } }, 1);
            },
            .corner => s.add(.{ .arc = .{ .x = segment.cx, .y = segment.cy, .r = r, .w = w, .start = segment.start + a / r, .sweep = (b - a) / r, .cap = if (dash_cap == .round or end_cap == .round) .round else .flat } }, 1),
        }
        from = seg_end;
    }
}

fn rotate(x: f64, y: f64, angle: f64) [2]f64 {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ x * c + y * s, -x * s + y * c };
}
fn roundedBox(x: f64, y: f64, hw: f64, hh: f64, radius: f64) f64 {
    const r = @min(radius, @min(hw, hh));
    const qx = @abs(x) - (hw - r);
    const qy = @abs(y) - (hh - r);
    return @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - r;
}
fn segmentDistance(px: f64, py: f64, x0: f64, y0: f64, x1: f64, y1: f64) f64 {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len2 = dx * dx + dy * dy;
    const h = if (len2 > 0) std.math.clamp(((px - x0) * dx + (py - y0) * dy) / len2, 0, 1) else 0;
    const ex = px - x0 - dx * h;
    const ey = py - y0 - dy * h;
    return @sqrt(ex * ex + ey * ey);
}
fn angleFrom(start: f64, angle: f64) f64 {
    return frac((angle - start) / tau) * tau;
}

/// Signed distance in design units and an alpha factor at a point.
fn evaluate(shape: Shape, px: f64, py: f64) struct { d: f64, alpha: f64 = 1 } {
    switch (shape) {
        .disc => |v| return .{ .d = std.math.hypot(px - v.x, py - v.y) - v.r },
        .ring => |v| return .{ .d = @abs(std.math.hypot(px - v.x, py - v.y) - v.r) - v.w / 2 },
        .arc => |v| {
            const dx = px - v.x;
            const dy = py - v.y;
            const rho = std.math.hypot(dx, dy);
            const ring = @abs(rho - v.r) - v.w / 2;
            const offset = angleFrom(v.start, std.math.atan2(dy, dx));
            const sweep = @min(v.sweep, tau);
            const fade = if (v.fade) std.math.clamp(offset / @max(sweep, 1e-6), 0, 1) else 1;
            if (offset <= sweep) return .{ .d = ring, .alpha = fade };
            // Past either end: the cap decides.
            const ends = [2]f64{ v.start, v.start + sweep };
            var best: f64 = std.math.inf(f64);
            for (ends) |a| {
                const ex = v.x + v.r * @cos(a);
                const ey = v.y + v.r * @sin(a);
                if (v.cap == .round) {
                    best = @min(best, std.math.hypot(px - ex, py - ey) - v.w / 2);
                } else {
                    // Outside the sweep the nearest point is on an end's
                    // straight edge across the stroke.
                    const nx = @cos(a) * v.w / 2;
                    const ny = @sin(a) * v.w / 2;
                    best = @min(best, segmentDistance(px, py, ex - nx, ey - ny, ex + nx, ey + ny));
                }
            }
            const tail_alpha: f64 = if (v.fade) (if (offset - sweep < (tau - sweep) / 2) 1 else 0) else 1;
            return .{ .d = best, .alpha = tail_alpha };
        },
        .box => |v| {
            const p = rotate(px - v.x, py - v.y, v.angle);
            return .{ .d = roundedBox(p[0], p[1], v.hw, v.hh, v.radius) };
        },
        .capsule => |v| {
            if (v.cap == .round) return .{ .d = segmentDistance(px, py, v.x0, v.y0, v.x1, v.y1) - v.w / 2 };
            const dx = v.x1 - v.x0;
            const dy = v.y1 - v.y0;
            const len = std.math.hypot(dx, dy);
            if (len == 0) return .{ .d = std.math.inf(f64) };
            const angle = std.math.atan2(dy, dx);
            const p = rotate(px - (v.x0 + v.x1) / 2, py - (v.y0 + v.y1) / 2, angle);
            return .{ .d = roundedBox(p[0], p[1], len / 2, v.w / 2, 0) };
        },
        .ellipse => |v| {
            const p = rotate(px - v.x, py - v.y, v.angle);
            const ry = @max(@abs(v.ry), 0.2);
            const qx = p[0] / v.rx;
            const qy = p[1] / ry;
            const q = std.math.hypot(qx, qy);
            if (q == 0) return .{ .d = @min(v.rx, ry) - v.w / 2 };
            const gx = qx / (v.rx * q);
            const gy = qy / (ry * q);
            return .{ .d = @abs((q - 1) / std.math.hypot(gx, gy)) - v.w / 2 };
        },
        .sector => |v| {
            const dx = px - v.x;
            const dy = py - v.y;
            const behind = angleFrom(std.math.atan2(dy, dx), v.angle);
            const alpha = if (behind <= v.sweep) 1 - behind / v.sweep else 0;
            return .{ .d = std.math.hypot(dx, dy) - v.r, .alpha = alpha };
        },
    }
}

/// Rasterize an indicator into the target inside the surface's clip.
pub fn draw(surface: cpu.Surface, transparent: bool, entry: Entry) cpu.Dirty {
    const empty: cpu.Dirty = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (entry.color.a == 0) return empty;
    const s = scene(entry);
    const scale: f64 = surface.scale;
    const b = entry.bounds;
    const bx = @as(f64, b.x) * scale + surface.origin[0];
    const by = @as(f64, b.y) * scale + surface.origin[1];
    const bw = @as(f64, b.width) * scale;
    const bh = @as(f64, b.height) * scale;
    // Fit the view box inside the bounds, centered.
    const k = @min(bw / s.width, bh / unit);
    if (!(k > 0)) return empty;
    const ox = bx + (bw - s.width * k) / 2;
    const oy = by + (bh - unit * k) / 2;
    const clip = surface.clip;
    const x0: usize = @intFromFloat(std.math.clamp(@floor(@max(ox, clip[0])), 0, @as(f64, @floatFromInt(surface.width))));
    const y0: usize = @intFromFloat(std.math.clamp(@floor(@max(oy, clip[1])), 0, @as(f64, @floatFromInt(surface.height))));
    const x1: usize = @intFromFloat(std.math.clamp(@ceil(@min(ox + s.width * k, clip[2])), @as(f64, @floatFromInt(x0)), @as(f64, @floatFromInt(surface.width))));
    const y1: usize = @intFromFloat(std.math.clamp(@ceil(@min(oy + unit * k, clip[3])), @as(f64, @floatFromInt(y0)), @as(f64, @floatFromInt(surface.height))));
    if (x1 <= x0 or y1 <= y0) return empty;
    const aa = 1 / k;
    const rgb = (@as(u32, entry.color.r) << 16) | (@as(u32, entry.color.g) << 8) | entry.color.b;
    const opacity = @as(f64, @floatFromInt(entry.color.a)) / 255;
    for (y0..y1) |y| for (x0..x1) |x| {
        const fx: f64 = @floatFromInt(x);
        const fy: f64 = @floatFromInt(y);
        const px = (fx + 0.5 - ox) / k;
        const py = (fy + 0.5 - oy) / k;
        var total: f64 = 0;
        for (s.elements[0..s.len]) |element| {
            const value = evaluate(element.shape, px, py);
            const a = std.math.clamp(0.5 - value.d / aa, 0, 1) * element.alpha * value.alpha;
            total = a + total * (1 - a);
        }
        const clip_amount = @max(0, @min(fx + 1, clip[2]) - @max(fx, clip[0])) * @max(0, @min(fy + 1, clip[3]) - @max(fy, clip[1]));
        const alpha: u32 = @intFromFloat(@round(std.math.clamp(total * opacity * clip_amount, 0, 1) * 255));
        if (alpha == 0) continue;
        const at = y * surface.stride + x;
        const source = composite.tintByte(rgb, alpha);
        surface.pixels[at] = if (transparent) composite.overFull(source, surface.pixels[at]) else composite.overFull(source, surface.pixels[at] | 0xff000000);
    };
    return .{ .left = @intCast(x0), .top = @intCast(y0), .right = @intCast(x1), .bottom = @intCast(y1) };
}

fn coverageOf(kind: Kind, t: f64, options: Options) struct { ink: u32, pixels: [48 * 24]u32 } {
    var pixels = [_]u32{0xffffffff} ** (48 * 24);
    const surface: cpu.Surface = .{ .pixels = &pixels, .width = 48, .height = 24, .stride = 48, .scale = 1, .clip = .{ 0, 0, 48, 24 } };
    _ = draw(surface, false, .{ .bounds = .{ .x = 0, .y = 0, .width = 24 * kind.aspect(), .height = 24 }, .kind = kind, .phase = t, .color = .rgb(0), .options = options });
    var ink: u32 = 0;
    for (pixels) |pixel| ink += 255 - (pixel & 255);
    return .{ .ink = ink, .pixels = pixels };
}

test "every indicator draws ink inside its bounds and changes over a cycle" {
    for (all) |kind| {
        const start = coverageOf(kind, 0.1, .{});
        try std.testing.expect(start.ink > 255 * 4);
        const later = coverageOf(kind, 0.37, .{});
        try std.testing.expect(!std.mem.eql(u32, &start.pixels, &later.pixels));
        // Whole cycles repeat the pose.
        const repeated = coverageOf(kind, 3.1, .{});
        var difference: u32 = 0;
        for (start.pixels, repeated.pixels) |a, b| difference = @max(difference, @as(u32, @intCast(@abs(@as(i32, @intCast(a & 255)) - @as(i32, @intCast(b & 255))))));
        try std.testing.expect(difference <= 2);
        try std.testing.expect(kind.cycle() >= 500 * std.time.ns_per_ms);
        try std.testing.expect(kind.name().len != 0);
        // Nothing lands outside the view box.
        if (kind.aspect() == 1) for (0..24) |y| for (24..48) |x| {
            try std.testing.expectEqual(@as(u32, 0xffffffff), start.pixels[y * 48 + x]);
        };
    }
    try std.testing.expectEqual(@as(usize, 29), all.len);
}

test "options vary the indicators they apply to" {
    try std.testing.expect(!std.mem.eql(u32, &coverageOf(.arc, 0.2, .{}).pixels, &coverageOf(.arc, 0.2, .{ .cap = .flat }).pixels));
    try std.testing.expect(!std.mem.eql(u32, &coverageOf(.ring, 0.2, .{}).pixels, &coverageOf(.ring, 0.2, .{ .easing = .ease_in_out }).pixels));
    try std.testing.expect(!std.mem.eql(u32, &coverageOf(.blocks, 0.2, .{}).pixels, &coverageOf(.blocks, 0.2, .{ .sweep = .rows }).pixels));
    try std.testing.expect(!std.mem.eql(u32, &coverageOf(.ripple, 0.2, .{}).pixels, &coverageOf(.ripple, 0.2, .{ .direction = .in }).pixels));
    try std.testing.expect(!std.mem.eql(u32, &coverageOf(.wave, 0.2, .{}).pixels, &coverageOf(.wave, 0.2, .{ .origin = .bottom }).pixels));
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), phase(.arc, 1200 * std.time.ns_per_ms, 0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), phase(.arc, 500 * std.time.ns_per_ms, 1000 * std.time.ns_per_ms), 1e-9);
}

test "indicators respect the clip and keep alpha on transparent planes" {
    var pixels = [_]u32{0} ** (24 * 24);
    var surface: cpu.Surface = .{ .pixels = &pixels, .width = 24, .height = 24, .stride = 24, .scale = 1, .clip = .{ 0, 0, 12, 24 } };
    const dirty = draw(surface, true, .{ .bounds = .{ .x = 0, .y = 0, .width = 24, .height = 24 }, .kind = .ring, .phase = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 } });
    try std.testing.expect(dirty.right <= 12);
    for (0..24) |y| for (12..24) |x| try std.testing.expectEqual(@as(u32, 0), pixels[y * 24 + x]);
    var ink = false;
    for (pixels) |pixel| if (pixel >> 24 != 0) {
        ink = true;
        try std.testing.expect(((pixel >> 16) & 255) <= pixel >> 24);
    };
    try std.testing.expect(ink);
    surface.clip = .{ 0, 0, 24, 24 };
    const none = draw(surface, true, .{ .bounds = .{ .x = 0, .y = 0, .width = 24, .height = 24 }, .kind = .ring, .phase = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } });
    try std.testing.expectEqual(@as(u32, 0), none.right);
}
