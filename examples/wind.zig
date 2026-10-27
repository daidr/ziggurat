//! A field of monospaced characters that a wind lights in passing gusts,
//! curling, streaked and thinning around the content, while each character
//! steps through a set of its own. Moving the pointer warms the air along
//! its path; a click blows a ripple out from it, tinted, and every third
//! click blows a heart.
//!
//! The texture is worked out on the CPU, as a pair of fragment shaders
//! would: the wind at two samples a cell, then each pixel of the glyphs'
//! ink, from an atlas of the system's monospaced font (its outlines
//! rasterized once), lit by the wind's samples around it, more where its
//! edge faces the wind. A thread of its own draws each frame, with helpers
//! sharing the rows, into a `ui.PixelImage` behind the content. Every visit
//! has a wind of its own, picked by a random seed; Ctrl+R starts another.
//! After three minutes without input the wind settles and the texture fades
//! out, to come back at the next move.
//!
//! Run it with `zig build run-wind`.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const text = @import("ziggurat_view_text");
const outlines = @import("ziggurat_text_outlines");
const vector = @import("ziggurat_vector");

const window_width = 1100;
const window_height = 720;

// The texture's randomness: PCG hashes of whole numbers, and value and
// gradient noise on them.

fn pcg(v: u32) u32 {
    const s = v *% 747796405 +% 2891336453;
    const w = ((s >> @intCast((s >> 28) + 4)) ^ s) *% 277803737;
    return (w >> 22) ^ w;
}

/// `h` as a fraction from 0 to 1, from its top 24 bits.
fn unit(h: u32) f32 {
    return @as(f32, @floatFromInt(h >> 8)) * (1.0 / 16777216.0);
}

/// The fade of the noises between lattice points, whose first and second
/// derivatives are 0 at both ends.
fn quintic(f: f32) f32 {
    return f * f * f * (f * (f * 6 - 15) + 10);
}

fn mix(a: f32, b: f32, k: f32) f32 {
    return a + (b - a) * k;
}

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const k = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return k * k * (3 - 2 * k);
}

fn lattice(x: f32) u32 {
    return @bitCast(@as(i32, @intFromFloat(x)));
}

/// The hashes of a point of the noises' lattice: its two columns, and its
/// four rows in its two layers, from which a corner's hash is its
/// column's.
const Lattice = struct {
    x0: u32,
    x1: u32,
    a: u32,
    b: u32,
    c: u32,
    d: u32,
    f: [3]f32,
    w: [3]f32,

    fn of(seed: u32, x: f32, y: f32, zz: f32, salt: u32) Lattice {
        const fx = @floor(x);
        const fy = @floor(y);
        const fz = @floor(zz);
        const z0 = pcg(lattice(fz) ^ seed ^ salt);
        const z1 = pcg(lattice(fz) +% 1 ^ seed ^ salt);
        const y0 = lattice(fy);
        const y1 = y0 +% 1;
        const f = [3]f32{ x - fx, y - fy, zz - fz };
        return .{ .x0 = lattice(fx), .x1 = lattice(fx) +% 1, .a = pcg(y0 ^ z0), .b = pcg(y1 ^ z0), .c = pcg(y0 ^ z1), .d = pcg(y1 ^ z1), .f = f, .w = .{ quintic(f[0]), quintic(f[1]), quintic(f[2]) } };
    }
};

fn corner(h: u32) f32 {
    return unit(pcg(h)) * 2 - 1;
}

/// Value noise from -1 to 1: a random value at each lattice point, blended
/// between them.
fn value(seed: u32, x: f32, y: f32, zz: f32, salt: u32) f32 {
    const l = Lattice.of(seed, x, y, zz, salt);
    return mix(
        mix(mix(corner(l.x0 ^ l.a), corner(l.x1 ^ l.a), l.w[0]), mix(corner(l.x0 ^ l.b), corner(l.x1 ^ l.b), l.w[0]), l.w[1]),
        mix(mix(corner(l.x0 ^ l.c), corner(l.x1 ^ l.c), l.w[0]), mix(corner(l.x0 ^ l.d), corner(l.x1 ^ l.d), l.w[0]), l.w[1]),
        l.w[2],
    );
}

fn slope(h: u32, fx: f32, fy: f32, fz: f32) f32 {
    const k = pcg(h);
    const sx = @as(f32, @floatFromInt(k & 1023)) * (2.0 / 1023.0) - 1;
    const sy = @as(f32, @floatFromInt((k >> 10) & 1023)) * (2.0 / 1023.0) - 1;
    const sz = @as(f32, @floatFromInt((k >> 20) & 1023)) * (2.0 / 1023.0) - 1;
    return sx * fx + sy * fy + sz * fz;
}

/// Gradient noise on the same lattice, about -1 to 1.
fn swirl(seed: u32, x: f32, y: f32, zz: f32, salt: u32) f32 {
    const l = Lattice.of(seed, x, y, zz, salt);
    const f = l.f;
    return 1.5 * mix(
        mix(mix(slope(l.x0 ^ l.a, f[0], f[1], f[2]), slope(l.x1 ^ l.a, f[0] - 1, f[1], f[2]), l.w[0]), mix(slope(l.x0 ^ l.b, f[0], f[1] - 1, f[2]), slope(l.x1 ^ l.b, f[0] - 1, f[1] - 1, f[2]), l.w[0]), l.w[1]),
        mix(mix(slope(l.x0 ^ l.c, f[0], f[1], f[2] - 1), slope(l.x1 ^ l.c, f[0] - 1, f[1], f[2] - 1), l.w[0]), mix(slope(l.x0 ^ l.d, f[0], f[1] - 1, f[2] - 1), slope(l.x1 ^ l.d, f[0] - 1, f[1] - 1, f[2] - 1), l.w[0]), l.w[1]),
        l.w[2],
    );
}

/// Scrambles the bits of v, as an integer hash.
fn mix32(input: u32) u32 {
    var v = input;
    v = (v ^ v >> 16) *% 569420461;
    v = (v ^ v >> 15) *% 1935289751;
    return v ^ v >> 15;
}

/// Numbers from 0 to 1, a sequence of its own for each seed and salt.
const Random = struct {
    n: u32,

    fn init(seed: u32, salt: []const u8) Random {
        var n = mix32(seed);
        for (salt) |c| n = mix32(n ^ c);
        return .{ .n = n };
    }
    fn next(self: *Random) f64 {
        self.n +%= 0x9E3779B9;
        return @as(f64, @floatFromInt(mix32(self.n))) / 4294967296;
    }
};

/// The characters an atlas holds, ASCII's printable ones and a middle dot,
/// sixteen to a row.
const charset = [_][]const u8{ " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?", "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_", "`", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "{", "|", "}", "~", "·" };

/// The sets of characters a visit shows, each a sequence that a cell steps
/// through from a place of its own.
const Look = struct { name: []const u8, chars: []const u8 };
const looks = [_]Look{
    .{ .name = "mixed", .chars = "ab0cAde1fEgh2iGjk3lHmn4oKpq5rMst6uRvw7xSyz8nT9eW" },
    .{ .name = "lettered", .chars = "abcd3efgRhijk7lmnAopqr0stuEvwxy5zaeKiou2gcS9" },
    .{ .name = "figured", .chars = "0a1b2C3d4e5F6g7h8i9J0k1m2N3p4q5R6s7t8U9v0w1X2y3z" },
};

fn indexOf(c: u8) ?usize {
    for (charset, 0..) |s, i| if (s.len == 1 and s[0] == c) return i;
    return null;
}

/// A visit's wind, which its seed picks: its look; the heading it blows
/// toward, in radians with y down; its speed, in DIPs a second; the length
/// and width of a gust; and how far its path bends, and the size of a bend.
const Wind = struct {
    seed: u32,
    look: usize,
    heading: f32,
    speed: f32,
    gust_length: f32,
    gust_width: f32,
    bend: f32,
    bend_scale: f32,

    fn init(seed: u32, look: usize) Wind {
        var random: Random = .init(seed, "wind");
        const heading = headingOf(random.next());
        var w: Wind = .{ .seed = seed, .look = look, .heading = heading, .speed = 0, .gust_length = 0, .gust_width = 0, .bend = 0, .bend_scale = 0 };
        inline for (.{ .{ "speed", 42, 64 }, .{ "gust_length", 380, 560 }, .{ "gust_width", 120, 190 }, .{ "bend", 60, 110 }, .{ "bend_scale", 300, 440 } }) |field| {
            @field(w, field[0]) = field[1] + (field[2] - field[1]) * @as(f32, @floatCast(random.next()));
        }
        return w;
    }

    /// How far the wind has carried its gusts by its time, surging and
    /// slackening as it goes.
    fn carried(self: Wind, time: f32) f32 {
        return self.speed * (time + value(self.seed, time * 0.09, 3.7, 0, 0x58));
    }

    /// The span of its long swells over a canvas of w×h DIPs, about one to
    /// it.
    fn span(self: Wind, w: f32, h: f32) f32 {
        return 0.58 * (@abs(@cos(self.heading)) * w + @abs(@sin(self.heading)) * h);
    }
};

/// The heading of a fraction e: across the pane and down it, from 18° to
/// 42° below the horizontal, rightward for e below 0.5 and leftward above.
fn headingOf(e: f64) f32 {
    const lo = std.math.pi / 10.0;
    const a = lo + (std.math.pi / 4.3 - lo) * @mod(e * 2, 1);
    return @floatCast(if (e < 0.5) a else std.math.pi - a);
}

/// The look of seed among those not in recent, or not the latest of them.
fn pickLook(seed: u32, recent: []const usize) usize {
    var fresh: [looks.len]usize = undefined;
    var fresh_len: usize = 0;
    var not_last: [looks.len]usize = undefined;
    var not_last_len: usize = 0;
    for (0..looks.len) |i| {
        if (std.mem.indexOfScalar(usize, recent, i) == null) {
            fresh[fresh_len] = i;
            fresh_len += 1;
        }
        if (recent.len == 0 or recent[0] != i) {
            not_last[not_last_len] = i;
            not_last_len += 1;
        }
    }
    const all = [_]usize{ 0, 1, 2 };
    const pick: []const usize = if (fresh_len > 0) fresh[0..fresh_len] else if (not_last_len > 0) not_last[0..not_last_len] else &all;
    var random: Random = .init(seed, "look");
    return pick[@intFromFloat(random.next() * @as(f64, @floatFromInt(pick.len)))];
}

// How the hand stirs the air: a click is a blow, whose front runs out from
// the pointer, and a moving pointer warms the air along its path.

// How long a blow and a stretch of the path last, in seconds, and how many
// of each the air keeps.
const tap_life = 3.6;
const wake_life = 2.4;
const max_taps = 6;
const max_wakes = 48;
// The speeds of the pointer, in DIPs a second, between which a move goes
// from stirring nothing to stirring it all.
const slow_speed = 60;
const fast_speed = 800;
// A stretch of the path is laid once the pointer went min_step DIPs and
// min_gap seconds from the last; a pause of rest_after seconds starts the
// path anew; the pointer's speed follows its moves over speed_lag seconds.
const min_step = 18;
const min_gap = 0.035;
const rest_after = 0.25;
const speed_lag = 0.08;
// How many clicks make a heart, a blow that runs out as a heart rather than
// a circle.
const heart_every = 3;

/// Up to n values in a fixed buffer.
fn Bounded(comptime T: type, comptime n: usize) type {
    return struct {
        buffer: [n]T = undefined,
        len: usize = 0,

        fn constSlice(self: *const @This()) []const T {
            return self.buffer[0..self.len];
        }
        fn appendAssumeCapacity(self: *@This(), item: T) void {
            self.buffer[self.len] = item;
            self.len += 1;
        }
    };
}

/// A click, or a stretch of the pointer's path: where, when and how hard;
/// and for a stretch, which way it runs, with half its length.
const Blow = struct { x: f32, y: f32, at: f32, force: f32 = 0, way_x: f32 = 0, way_y: f32 = 0 };

/// A stretch of the path as the air feels it now: its middle, how warm, one
/// over the square of how far that reaches, and which way it runs (a unit
/// vector) with half its length.
const Warmth = struct { x: f32, y: f32, heat: f32, reach: f32, dir_x: f32, dir_y: f32, half: f32 };

/// What the pointer did, in DIPs of the pane and seconds of the texture's
/// clock.
const Hand = struct {
    taps: Bounded(Blow, max_taps) = .{},
    wakes: Bounded(Blow, max_wakes) = .{},
    clicks: u32 = 0,
    /// The pointer as it last moved, and as it was where the last stretch
    /// ended; speed is its speed, smoothed.
    last: ?Blow = null,
    from: ?Blow = null,
    speed: f32 = 0,
    /// As of the frame: its time, and the warmth of the path.
    now: f32 = 0,
    warm: Bounded(Warmth, max_wakes) = .{},

    /// The pointer moved to (x, y) at `at`. A pause starts the path anew.
    fn move(self: *Hand, x: f32, y: f32, at: f32) void {
        const last = self.last orelse return self.restart(x, y, at);
        const from = self.from orelse return self.restart(x, y, at);
        if (at - last.at > rest_after) return self.restart(x, y, at);
        const dt = @max(at - last.at, 1.0 / 240.0);
        self.speed += (std.math.hypot(x - last.x, y - last.y) / dt - self.speed) * @min(1, dt / speed_lag);
        self.last = .{ .x = x, .y = y, .at = at };
        const l = std.math.hypot(x - from.x, y - from.y);
        if (l < min_step or at - from.at < min_gap) return;
        const force = smoothstep(0, 1, (self.speed - slow_speed) / (fast_speed - slow_speed));
        self.from = self.last;
        if (force < 0.04) return;
        keep(&self.wakes, max_wakes - 1);
        self.wakes.appendAssumeCapacity(.{ .x = (x + from.x) / 2, .y = (y + from.y) / 2, .at = at, .force = force * l / (l + 90), .way_x = (x - from.x) / 2, .way_y = (y - from.y) / 2 });
    }

    fn restart(self: *Hand, x: f32, y: f32, at: f32) void {
        self.last = .{ .x = x, .y = y, .at = at };
        self.from = self.last;
        self.speed = 0;
    }

    /// A click at (x, y) at `at`: every heart_every-th is a heart.
    fn tap(self: *Hand, x: f32, y: f32, at: f32) void {
        self.clicks += 1;
        keep(&self.taps, max_taps - 1);
        self.taps.appendAssumeCapacity(.{ .x = x, .y = y, .at = at, .force = if (self.clicks % heart_every == 0) -1.15 else 1 });
    }

    /// Whether a blow or a stretch of the path still stirs the air at
    /// `at`; rippling whether a blow does.
    fn busy(self: *const Hand, at: f32) bool {
        return self.rippling(at) or anyAfter(self.wakes.constSlice(), at - wake_life);
    }
    fn rippling(self: *const Hand, at: f32) bool {
        return anyAfter(self.taps.constSlice(), at - tap_life);
    }

    /// Readies the hand for a frame at `at`: blows and stretches that died
    /// down go, and each stretch's warmth is worked out, rising quickly and
    /// falling slowly, reaching further as it ages, and weaker the older the
    /// path behind it.
    fn frame(self: *Hand, at: f32) void {
        self.now = at;
        keepAfter(&self.taps, at - tap_life);
        keepAfter(&self.wakes, at - wake_life);
        self.warm.len = 0;
        const older = max_wakes - self.wakes.len;
        for (self.wakes.constSlice(), 0..) |w, i| {
            const age = @max(0, at - w.at);
            const heat = w.force * @min(1, @as(f32, @floatFromInt(i + 1 + older)) / 8) * (1 - @exp(-age / 0.05)) * @exp(-age / 0.65);
            if (heat < 0.002) continue;
            const reach = 50 + 40 * age;
            const l = std.math.hypot(w.way_x, w.way_y);
            const div = if (l == 0) 1 else l;
            self.warm.appendAssumeCapacity(.{ .x = w.x, .y = w.y, .heat = heat, .reach = 1 / (reach * reach), .dir_x = w.way_x / div, .dir_y = w.way_y / div, .half = l });
        }
    }

    fn keep(list: anytype, n: usize) void {
        if (list.len <= n) return;
        const drop = list.len - n;
        std.mem.copyForwards(@TypeOf(list.buffer[0]), list.buffer[0..n], list.buffer[drop..list.len]);
        list.len = n;
    }
    fn keepAfter(list: anytype, at: f32) void {
        var out: usize = 0;
        for (list.constSlice()) |b| if (b.at > at) {
            list.buffer[out] = b;
            out += 1;
        };
        list.len = out;
    }
    fn anyAfter(list: []const Blow, at: f32) bool {
        for (list) |b| if (b.at > at) return true;
        return false;
    }
};

// The grid: cells cell_size DIPs wide and twice as high, at least min_cols
// by min_rows of them, and no more than max_pixels pixels in all.
const cell_size = 6.5;
const min_cols = 24;
const min_rows = 8;
const max_pixels = 21e6;

/// The cells of a pane: their size and count, and where the first lies,
/// in pixels; the grid is centered on the pane and overhangs it.
const Grid = struct {
    cell_w: i32,
    cell_h: i32,
    cols: i32,
    rows: i32,
    left: i32,
    top: i32,
    scale: f32,

    /// The grid of a pane of w×h pixels at scale pixels a DIP, or null for
    /// a pane too small for one.
    fn of(w: i32, h: i32, scale: f32) ?Grid {
        if (w <= 0 or h <= 0 or scale <= 0) return null;
        const cw: i32 = @max(5, @as(i32, @intFromFloat(@round(cell_size * scale))));
        var g: Grid = .{ .cell_w = cw, .cell_h = 2 * cw, .cols = @divFloor(w + cw - 1, cw), .rows = @divFloor(h + 2 * cw - 1, 2 * cw), .left = 0, .top = 0, .scale = scale };
        if (g.cols < min_cols or g.rows < min_rows) return null;
        const k = @as(f64, @floatFromInt(g.cols * g.cell_w)) * @as(f64, @floatFromInt(g.rows * g.cell_h)) / max_pixels;
        if (k > 1) {
            g.cols = @intFromFloat(@as(f64, @floatFromInt(g.cols)) / @sqrt(k));
            g.rows = @intFromFloat(@as(f64, @floatFromInt(g.rows)) / @sqrt(k));
        }
        g.left = @intFromFloat(@round(@as(f64, @floatFromInt(w - g.cols * g.cell_w)) / 2));
        g.top = @intFromFloat(@round(@as(f64, @floatFromInt(h - g.rows * g.cell_h)) / 2));
        return g;
    }

    /// The middle of a cell's column and row in the pane, in DIPs.
    fn cellX(self: Grid, cx: i32) f32 {
        return (@as(f32, @floatFromInt(self.left)) + (@as(f32, @floatFromInt(cx)) + 0.5) * @as(f32, @floatFromInt(self.cell_w))) / self.scale;
    }
    fn cellY(self: Grid, cy: i32) f32 {
        return (@as(f32, @floatFromInt(self.top)) + (@as(f32, @floatFromInt(cy)) + 0.5) * @as(f32, @floatFromInt(self.cell_h))) / self.scale;
    }
};

// The glyphs: glyph_size DIPs, in a light weight on screens of 1.5 pixels a
// DIP or more and a regular one on others, where a light stroke would break
// up; in the system's monospaced font.
const glyph_size = 9;
const family = if (builtin.os.tag == .windows) "Consolas" else "monospace";
/// The coverage from which a pixel counts in a glyph's box.
const ink_from = 8;

/// The charset rasterized for cells of cell_w×cell_h pixels: each
/// character's coverage, its box where the coverage reaches ink_from (left,
/// top, right and bottom, in pixels of its cell), and the characters the
/// font does not draw a cell wide.
const Atlas = struct {
    cell_w: i32,
    cell_h: i32,
    scale: f32,
    coverage: []u8,
    boxes: [charset.len][4]f32 = undefined,
    missing: [charset.len]bool = @splat(false),

    /// Rasterizes the charset for cells of cell_w pixels at scale pixels a
    /// DIP, as large as glyph_size allows in a cell with a pixel to spare
    /// either side, its baseline placed to center the font's ascent and
    /// descent, and each glyph centered as the zero's advance.
    fn init(allocator: std.mem.Allocator, engine: *t.Engine, cell_w: i32, scale: f32) !*Atlas {
        const cell_h = 2 * cell_w;
        const weight: u32 = if (scale < 1.5) 400 else 300;
        const self = try allocator.create(Atlas);
        errdefer allocator.destroy(self);
        self.* = .{ .cell_w = cell_w, .cell_h = cell_h, .scale = scale, .coverage = try allocator.alloc(u8, charset.len * @as(usize, @intCast(cell_w * cell_h))) };
        errdefer allocator.free(self.coverage);
        @memset(self.coverage, 0);
        var ratio: f32 = 0.6;
        {
            const probe = try engine.layout("0", .{ .family = family, .size = 100, .weight = weight });
            defer probe.close() catch {};
            const lines = try probe.lines();
            if (lines.len == 1 and lines[0].width > 0) ratio = lines[0].width / 100;
        }
        const w: f32 = @floatFromInt(cell_w);
        const h: f32 = @floatFromInt(cell_h);
        const px = @min(@round(glyph_size * scale), @floor((w - 2) / ratio));
        const size = px / scale;
        var zero: f32 = 0;
        var ascent: f32 = size * 0.8;
        var descent: f32 = size * 0.2;
        {
            const probe = try engine.layout("0", .{ .family = family, .size = size, .weight = weight });
            defer probe.close() catch {};
            const lines = try probe.lines();
            if (lines.len == 1) {
                zero = lines[0].width * scale;
                ascent = lines[0].baseline - lines[0].y;
                descent = lines[0].height - ascent;
            }
        }
        const base = @round((h - (ascent + descent) * scale) / 2 + ascent * scale);
        const left = @floor((w - zero) / 2);
        const area: usize = @intCast(cell_w * cell_h);
        for (charset, 0..) |glyph, i| {
            const cell = self.coverage[i * area ..][0..area];
            self.boxes[i] = .{ w, h, -1, -1 };
            if (std.mem.eql(u8, glyph, " ")) continue;
            const layout = try engine.layout(glyph, .{ .family = family, .size = size, .weight = weight });
            const lines = try layout.lines();
            const metrics = try layout.metrics();
            if (lines.len != 1 or metrics.missing_glyphs > 0 or @abs(lines[0].width * scale - zero) > 0.5) {
                try layout.close();
                self.missing[i] = true;
                continue;
            }
            const baseline = lines[0].baseline;
            const shape = outlines.fromLayout(layout, allocator, .{}) catch |err| {
                try layout.close();
                return err;
            };
            try layout.close();
            defer shape.close() catch {};
            const path = try shape.path();
            const prepared = try path.prepare(allocator, .{
                .main_thread = std.Thread.getCurrentId(),
                .viewport = .{ .x = 0, .y = 0, .width = w / scale, .height = h / scale },
                .scale = scale,
                .transform = .{ .x0 = left / scale, .y0 = base / scale - baseline },
            });
            defer prepared.close() catch {};
            const mask = prepared.coverage;
            for (0..mask.height) |row| for (0..mask.width) |col| {
                const x = @as(i64, mask.origin_x) + @as(i64, @intCast(col));
                const y = @as(i64, mask.origin_y) + @as(i64, @intCast(row));
                if (x < 0 or y < 0 or x >= cell_w or y >= cell_h) continue;
                const c = mask.pixels[row * mask.stride + col];
                const at: usize = @intCast(y * cell_w + x);
                cell[at] = c;
                if (c >= ink_from) {
                    const fx: f32 = @floatFromInt(x);
                    const fy: f32 = @floatFromInt(y);
                    self.boxes[i] = .{ @min(self.boxes[i][0], fx), @min(self.boxes[i][1], fy), @max(self.boxes[i][2], fx), @max(self.boxes[i][3], fy) };
                }
            };
        }
        return self;
    }

    fn deinit(self: *Atlas, allocator: std.mem.Allocator) void {
        allocator.free(self.coverage);
        allocator.destroy(self);
    }

    /// The characters of look that the atlas draws, as indexes of charset.
    fn sequence(self: *const Atlas, look: usize, out: *[64]u8) []const u8 {
        var len: usize = 0;
        for (looks[look].chars) |c| if (indexOf(c)) |i| if (i > 0 and !self.missing[i]) {
            out[len] = @intCast(i);
            len += 1;
        };
        if (len == 0) {
            out[0] = @intCast(indexOf('.').?);
            len = 1;
        }
        return out[0..len];
    }

    /// The coverage of character `c` at (x, y) of its cell, clamped to the
    /// cell, from 0 to 1.
    fn ink(self: *const Atlas, c: usize, x: f32, y: f32) f32 {
        const cx: i32 = @intFromFloat(std.math.clamp(x, 0, @as(f32, @floatFromInt(self.cell_w - 1))));
        const cy: i32 = @intFromFloat(std.math.clamp(y, 0, @as(f32, @floatFromInt(self.cell_h - 1))));
        const area: usize = @intCast(self.cell_w * self.cell_h);
        return @as(f32, @floatFromInt(self.coverage[c * area + @as(usize, @intCast(cy * self.cell_w + cx))])) / 255;
    }
};

/// Everything a frame's two passes read: the shaders' uniforms.
const Frame = struct {
    seed: u32,
    time: f32,
    reveal: f32,
    heading: [2]f32,
    carried: f32,
    span: f32,
    gust_length: f32,
    gust_width: f32,
    bend: f32,
    bend_scale: f32,
    /// The pane's size, and the samples': the first's corner and the
    /// distance between two, in DIPs.
    pane: [2]f32,
    origin: [2]f32,
    step: [2]f32,
    /// The hand's clock, its clicks' blows and its path's warmth.
    now: f32,
    taps: [max_taps]Blow = undefined,
    tap_count: usize = 0,
    warm: [max_wakes]Warmth = undefined,
    warm_count: usize = 0,
    grid: Grid,
    atlas: *const Atlas,
    seq: [64]u8 = undefined,
    seq_len: usize = 0,
    glow: [3]f32,
    opacity: f32,
    /// The pane's size in pixels.
    width: usize,
    height: usize,
};

// The wind's field: lull, streak, detail, edge, curl, wisp, tail, sweep and
// morph shape its gusts, card_y is how far down the content's middle is,
// and calm_left how much light shows behind it.
const lull = 0.5;
const streak = 0.4;
const detail = 0.6;
const edge = 0.75;
const curl = 0.65;
const wisp = 0.5;
const tail = 0.35;
const sweep = 0.3;
const morph = 3.0;
const card_y = 0.45;
const calm_left = 0.3;
const tau = 6.2831853;

/// How gusty the air is at (x, y) in the wind's own frame: four sizes of
/// gust travelling nearly together, thin strands between, and the long
/// swells they gather on.
fn gusts(f: *const Frame, x: f32, y: f32) f32 {
    const gain = mix(0.38, 0.62, detail);
    var gust: f32 = 0;
    var weight: f32 = 1;
    var power: f32 = 0;
    var sx = 0.85 * f.gust_length;
    var sy = 0.75 * f.gust_width;
    for (0..4) |i| {
        const k: f32 = @floatFromInt(i);
        gust += weight * swirl(f.seed, (x - f.carried * (1 + 0.1 * k)) / sx, y / sy, morph * f.time * (0.03 + 0.018 * k) + 11 * k, 0x60 + @as(u32, @intCast(i)));
        power += weight * weight;
        weight *= gain;
        sx *= 0.5;
        sy *= 0.58;
    }
    const strand = 1 - @abs(swirl(f.seed, (x - 1.15 * f.carried) / (0.7 * f.gust_length), y / (0.95 * f.gust_width), morph * f.time * 0.05 + 2, 0x66));
    const swell = @cos((x - f.carried + 0.5 * f.span * value(f.seed, f.time * 0.045, y / (2.5 * f.gust_width), 7, 0x67)) * (tau / f.span));
    return gust / @sqrt(power) + wisp * 0.5 * (strand * strand * strand - 0.35) + sweep * swell;
}

/// How far out a heart's outline lies in a direction (a unit vector, y
/// down), against a circle's 1.
fn heart(ux: f32, uy: f32) f32 {
    const k = -ux * ux * uy * uy * uy;
    const c = std.math.sign(k) * std.math.pow(f32, @abs(k), 1.0 / 3.0);
    var r: f32 = 1;
    for (0..6) |_| r = @sqrt(@max(0.05, 1 + c * std.math.pow(f32, r, 5.0 / 3.0)));
    return r;
}

/// A blow's front at (x, y): how far behind it, and how strong.
const Front = struct { away_x: f32, away_y: f32, d: f32, behind: f32, front: f32, age: f32 };

fn frontOf(tap: Blow, now: f32, x: f32, y: f32) Front {
    const age = now - tap.at;
    const away_x = x - tap.x;
    const away_y = y - tap.y;
    const dist = std.math.hypot(away_x, away_y);
    const reach = if (tap.force < 0) dist / heart(away_x / @max(dist, 1), away_y / @max(dist, 1)) else dist;
    const behind = 620 * (1 - @exp(-age / 1.3)) - reach;
    const width = 85 + 60 * age;
    return .{ .away_x = away_x, .away_y = away_y, .d = dist, .behind = behind, .front = smoothstep(-16, 10, behind) * @exp(-behind * behind / (width * width)), .age = age };
}

/// The clicks' push at (x, y), in DIPs, the wind they raise or lower and
/// how roused the air is: a click is a blow, whose front runs out and
/// slows, shoving the air outward; less than nothing, a heart.
fn pushes(f: *const Frame, x: f32, y: f32) [4]f32 {
    var sum: [4]f32 = @splat(0);
    for (f.taps[0..f.tap_count]) |tap| {
        const b = frontOf(tap, f.now, x, y);
        const swell = @abs(tap.force) * @exp(-b.age / 1.5) * b.front;
        sum[0] += b.away_x / @max(b.d, 1) * (44 * swell);
        sum[1] += b.away_y / @max(b.d, 1) * (44 * swell);
        sum[2] += 1.9 * swell * (0.25 + 0.75 * @cos(b.behind * (tau / 130.0)));
        sum[3] += swell;
    }
    return sum;
}

/// How warm the pointer's path left the air at (x, y), from 0 to 1.
fn warmth(f: *const Frame, x: f32, y: f32) f32 {
    var w: f32 = 0;
    for (f.warm[0..f.warm_count]) |wake| {
        var ax = x - wake.x;
        var ay = y - wake.y;
        const along = std.math.clamp(ax * wake.dir_x + ay * wake.dir_y, -wake.half, wake.half);
        ax -= wake.dir_x * along;
        ay -= wake.dir_y * along;
        w += wake.heat * @exp(-(ax * ax + ay * ay) * wake.reach);
    }
    return 1 - @exp(-1.5 * w);
}

/// The wind at a sample of the field, (col, row): how lit, which way the
/// air blows there (a unit vector), and how much of the resting light
/// shows.
fn windAt(f: *const Frame, col: usize, row: usize) [4]f32 {
    const px = f.origin[0] + (@as(f32, @floatFromInt(col)) + 0.5) * f.step[0];
    const py = f.origin[1] + (@as(f32, @floatFromInt(row)) + 0.5) * f.step[1];
    var hand: [4]f32 = @splat(0);
    var warm: f32 = 0;
    if (f.tap_count + f.warm_count > 0) {
        // Read a little off true, so that a ripple's outline is never a
        // drawn circle.
        const nx = px + 24 * value(f.seed, px / 95, py / 95, f.now * 0.12, 0x71);
        const ny = py + 24 * value(f.seed, px / 95 + 9.1, py / 95 + 9.1, f.now * 0.12 + 4, 0x72);
        hand = pushes(f, nx, ny);
        warm = warmth(f, nx, ny);
        hand[2] += 0.25 * warm;
        hand[3] += 0.05 * warm;
    }
    // Air that was pushed shows here what was over there, and the wind's
    // path bends, slowly, carrying it along.
    const fx = px - hand[0];
    const fy = py - hand[1];
    const turn_x = value(f.seed, fx / f.bend_scale, fy / f.bend_scale, f.time * 0.04, 0x51);
    const turn_y = value(f.seed, fx / f.bend_scale + 17.3, fy / f.bend_scale + 17.3, f.time * 0.04 + 5, 0x52);
    const bx = fx + f.bend * turn_x;
    const by = fy + f.bend * turn_y;
    const hx = f.heading[0];
    const hy = f.heading[1];
    const qx = bx * hx + by * hy;
    const qy = bx * -hy + by * hx;

    // The air curls: small eddies carried on large ones, and the smallest
    // folds, two or three rows of characters across.
    const rx = qx - 0.85 * f.carried;
    const ry = qy;
    const eddy_size = 1.15 * f.gust_width;
    const fine_size = 0.38 * f.gust_width;
    const ex = swirl(f.seed, rx / eddy_size, ry / eddy_size, morph * f.time * 0.04, 0x59);
    const ey = swirl(f.seed, rx / eddy_size + 31.7, ry / eddy_size + 31.7, morph * f.time * 0.04 + 3, 0x5a);
    const fold_x = rx + curl * 0.9 * f.gust_width * ex;
    const fold_y = ry + curl * 0.9 * f.gust_width * ey;
    const fine_x = swirl(f.seed, fold_x / fine_size, fold_y / fine_size, morph * f.time * 0.06, 0x5b);
    const fine_y = swirl(f.seed, fold_x / fine_size + 13.1, fold_y / fine_size + 13.1, morph * f.time * 0.06 + 7, 0x5c);
    const cx = (fold_x + 0.3 * f.gust_width * fine_x) / 24;
    const cy = (fold_y + 0.3 * f.gust_width * fine_y) / 24;
    const tiny_x = swirl(f.seed, cx, cy, f.time * 0.07, 0x5d);
    const tiny_y = swirl(f.seed, cx + 5.3, cy + 5.3, f.time * 0.07 + 1, 0x5e);
    const pull = curl * (1 + 0.9 * @min(hand[3], 1.5));
    const curled_x = qx + pull * (f.gust_width * (0.9 * ex + 0.3 * fine_x) + detail * 30 * tiny_x);
    const curled_y = qy + pull * (f.gust_width * (0.9 * ey + 0.3 * fine_y) + detail * 30 * tiny_y);
    const ax = 0.45 * ex + 0.25 * fine_x;
    const ay = 0.45 * ey + 0.25 * fine_y;
    var blow_x = hx + 0.6 * turn_x + hand[0] / 14 + curl * (ax * hx + ay * -hy);
    var blow_y = hy + 0.6 * turn_y + hand[1] / 14 + curl * (ax * hy + ay * hx);
    const length = @max(std.math.hypot(blow_x, blow_y), 1e-6);
    blow_x /= length;
    blow_y /= length;

    const still = gusts(f, curled_x, curled_y);
    const field = still + hand[2];
    // Light begins at once on the side a gust heads for and thins out
    // behind it.
    const level = mix(0.02, 0.82, lull);
    const band = mix(0.26, 0.03, edge);
    const blowing = field > level - band - 0.55 * tail;
    var strength: f32 = 0;
    var streaks: f32 = 0;
    if (blowing or warm > 0) {
        const thread = value(f.seed, (curled_x - f.carried * 1.6) / 140, curled_y / 30, f.time * 0.16, 0x57);
        streaks = 1 - smoothstep(0, 0.5, @abs(thread));
    }
    if (blowing) {
        const ahead = gusts(f, curled_x + 56, curled_y);
        const leaving = smoothstep(-0.05, 0.07, ahead - still);
        const lit = smoothstep(level - band - 0.55 * tail * leaving, level + band, field);
        const broad = lit * lit * mix(0.45, 1, std.math.clamp((field - level) / 0.45, 0, 1)) * (0.82 + 0.18 * fine_y);
        strength = broad * mix(1, 0.25 + 0.95 * streaks, streak);
    }
    if (warm > 0) {
        const grain = 0.55 * fine_y + 0.45 * tiny_x + 0.3 * (streaks - 0.4);
        strength = 1 - (1 - strength) * (1 - 0.85 * warm * smoothstep(-0.5, 0.25, grain));
    }

    // Thinner behind the content.
    const kx = (px - 0.5 * f.pane[0]) / 250;
    const ky = (py - card_y * f.pane[1]) / 80;
    const calm = 1 - (1 - calm_left) * @exp(-0.9 * (kx * kx + ky * ky));
    const shown = @max(f.reveal, @min(1, 2 * hand[3] + warm));
    return .{ strength * calm * shown, blow_x, blow_y, calm * shown };
}

// The glyphs: how fast the cells step through their characters, the light
// they keep at rest, how much a stroke's facing the wind matters, and how
// much stronger than the plain light the ripples' color may show.
const flick = 1.2;
const rest_light = 0.03;
const friction = 0.6;
const headroom = 3.0;
const ink_color = [3]f32{ 0x89.0 / 255.0, 0x87.0 / 255.0, 0x81.0 / 255.0 };
const glow_light = [3]f32{ 0, 0.25, 1 };
const glow_dark = [3]f32{ 0.1, 0.68, 1 };

/// What a cell shows this frame: its character, the ripples' color there
/// and their afterlight, or nothing.
const Cell = struct { char: u8 = 0, glow: [2]f32 = .{ 0, 0 }, empty: bool = true };

/// The wind's samples, four floats each, cols by 2 rows a cell.
const Field = struct {
    data: []f32 = &.{},
    width: usize = 0,
    height: usize = 0,

    fn at(self: *const Field, x: isize, y: isize) [4]f32 {
        const cx: usize = @intCast(std.math.clamp(x, 0, @as(isize, @intCast(self.width)) - 1));
        const cy: usize = @intCast(std.math.clamp(y, 0, @as(isize, @intCast(self.height)) - 1));
        return self.data[(cy * self.width + cx) * 4 ..][0..4].*;
    }

    /// The wind at (x, y) in samples, blended between the four nearest.
    fn sample(self: *const Field, x: f32, y: f32) [4]f32 {
        const fx = x - 0.5;
        const fy = y - 0.5;
        const x0 = @floor(fx);
        const y0 = @floor(fy);
        const kx = fx - x0;
        const ky = fy - y0;
        const ix: isize = @intFromFloat(x0);
        const iy: isize = @intFromFloat(y0);
        const a = self.at(ix, iy);
        const b = self.at(ix + 1, iy);
        const c = self.at(ix, iy + 1);
        const e = self.at(ix + 1, iy + 1);
        var out: [4]f32 = undefined;
        for (0..4) |i| out[i] = mix(mix(a[i], b[i], kx), mix(c[i], e[i], kx), ky);
        return out;
    }
};

/// Works out what cell (cx, cy) shows: each cell steps through the
/// characters at its own pace, from its own place among them, and a roused
/// one runs on, and back as it settles.
fn cellOf(f: *const Frame, field: *const Field, cx: i32, cy: i32) Cell {
    const h = pcg(@as(u32, @bitCast(cx)) *% 0x9E3779B9 ^ pcg(@as(u32, @bitCast(cy)) ^ f.seed));
    const pace = pcg(h);
    var steps: i64 = @intFromFloat(@floor(f.time * flick * (0.6 + 0.8 * unit(pace)) + unit(pcg(pace))));
    var glow: [2]f32 = .{ 0, 0 };
    if (f.tap_count > 0) {
        const x = f.grid.cellX(0) + @as(f32, @floatFromInt(cx)) * @as(f32, @floatFromInt(f.grid.cell_w)) / f.grid.scale;
        const y = f.grid.cellY(0) + @as(f32, @floatFromInt(cy)) * @as(f32, @floatFromInt(f.grid.cell_h)) / f.grid.scale;
        var roused: f32 = 0;
        for (f.taps[0..f.tap_count]) |tap| {
            const b = frontOf(tap, f.now, x, y);
            roused += @abs(tap.force) * @exp(-b.age / 1.5) * b.front;
            const trail = smoothstep(0, 70, b.behind) * @exp(-@max(b.behind, 0) / 260);
            glow[0] += @abs(tap.force) * (@exp(-b.age) * b.front + 0.7 * @exp(-b.age / 1.3) * trail);
            glow[1] += @abs(tap.force) * (1 - @exp(-b.age / 0.2)) * @exp(-b.age / 1.2) * trail;
        }
        steps += @intFromFloat(@floor(6 * roused + unit(pcg(pace ^ 0x33))));
        const k = 0.65 + 0.35 * unit(pcg(pace ^ 0x51));
        glow = .{ glow[0] * k, glow[1] * k };
    }
    if (glow[0] < 0.04 and glow[1] < 0.015) {
        // Without wind at the cell's samples or those around them, only its
        // resting light would be left, which cannot be seen.
        var most: f32 = 0;
        var y: isize = -1;
        while (y <= 2) : (y += 1) {
            var x: isize = -1;
            while (x <= 1) : (x += 1) most = @max(most, field.at(cx + x, 2 * cy + y)[0]);
        }
        if (most < 0.5 / 255.0) return .{};
    }
    const i: usize = @intCast(@mod(@as(i64, h >> 8) + steps, @as(i64, @intCast(f.seq_len))));
    return .{ .char = f.seq[i], .glow = glow, .empty = false };
}

/// The glyph's pixel at (x, y) of the grid, lit by the wind: premultiplied
/// color and alpha.
fn glyphAt(f: *const Frame, field: *const Field, cell: Cell, x: i32, y: i32) [4]f32 {
    const g = f.grid;
    const ax: f32 = @floatFromInt(@mod(x, g.cell_w));
    const ay: f32 = @floatFromInt(@mod(y, g.cell_h));
    const box = f.atlas.boxes[cell.char];
    if (ax < box[0] or ay < box[1] or ax > box[2] or ay > box[3]) return @splat(0);
    const atlas = f.atlas;
    const ink = atlas.ink(cell.char, ax, ay);
    if (ink <= 0) return @splat(0);

    // The wind, blended between its samples, and which way the stroke's
    // edge faces: into the ink from the side the wind comes from is a face
    // to the wind.
    const wind = field.sample((@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(g.cell_w)), (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(g.cell_h)) * 2);
    const rx = atlas.ink(cell.char, ax + 1, ay) - atlas.ink(cell.char, ax - 1, ay);
    const ry = atlas.ink(cell.char, ax, ay + 1) - atlas.ink(cell.char, ax, ay - 1);
    const steep = std.math.hypot(rx, ry);
    const facing: f32 = if (steep > 0.02) @max(0, (rx * wind[1] + ry * wind[2]) / steep) else 0.35;
    const caught = mix(1, 0.45 + 1.1 * facing, friction);
    const light = @min(1, wind[0] * caught) + rest_light * wind[3];
    // The color comes in whole and goes out quickly; the light is drawn
    // headroom times weaker than the canvas shows, which leaves room for
    // the ripples' color above it.
    const tint = smoothstep(0.04, 0.3, cell.glow[0]);
    const bright = @min(1, light) * mix(1, headroom, tint);
    const left = 0.3 * cell.glow[1] * wind[3];
    const a = ink * @min(1, (bright + left) / headroom);
    var out: [4]f32 = undefined;
    for (0..3) |i| out[i] = (mix(ink_color[i], f.glow[i], tint) * bright + f.glow[i] * left) / (bright + left + 0.0001) * a * f.opacity;
    out[3] = a * f.opacity;
    return out;
}

/// Draws frames on a thread of its own, with helpers sharing the rows, and
/// hands each to the window's thread when it is done.
const Renderer = struct {
    allocator: std.mem.Allocator,
    pool: std.Thread.Pool = undefined,
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    wake: std.Thread.Condition = .{},
    pending: ?Frame = null,
    quit: bool = false,
    /// Called on the drawing thread when a frame is done.
    done: ?*const fn (*Renderer) void = null,
    field: Field = .{},
    cells: []Cell = &.{},
    /// The finished frame, premultiplied BGRA, and its size.
    out: []u8 = &.{},
    width: usize = 0,
    height: usize = 0,

    fn start(self: *Renderer) !void {
        const helpers = @max(1, (std.Thread.getCpuCount() catch 2) -| 1);
        try self.pool.init(.{ .allocator = self.allocator, .n_jobs = helpers });
        errdefer self.pool.deinit();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn stop(self: *Renderer) void {
        if (self.thread) |thread| {
            self.mutex.lock();
            self.quit = true;
            self.wake.signal();
            self.mutex.unlock();
            thread.join();
            self.pool.deinit();
            self.thread = null;
        }
        self.allocator.free(self.field.data);
        self.allocator.free(self.cells);
        self.allocator.free(self.out);
        self.* = .{ .allocator = self.allocator };
    }

    /// Asks for a frame; the last frame must be done.
    fn ask(self: *Renderer, frame: Frame) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending = frame;
        self.wake.signal();
    }

    fn run(self: *Renderer) void {
        while (true) {
            self.mutex.lock();
            while (self.pending == null and !self.quit) self.wake.wait(&self.mutex);
            if (self.quit) return self.mutex.unlock();
            const frame = self.pending.?;
            self.pending = null;
            self.mutex.unlock();
            self.draw(&frame, true) catch |err| std.log.err("wind: {s}", .{@errorName(err)});
            if (self.done) |done| done(self);
        }
    }

    const Pass = enum { field, cells, glyphs };

    /// Draws the frame into `out`, sharing the rows with the helpers when
    /// `parallel`.
    fn draw(self: *Renderer, frame: *const Frame, parallel: bool) !void {
        const g = frame.grid;
        const fw: usize = @intCast(g.cols);
        const fh: usize = @intCast(2 * g.rows);
        if (self.field.width * self.field.height != fw * fh) self.field.data = try self.allocator.realloc(self.field.data, fw * fh * 4);
        self.field.width = fw;
        self.field.height = fh;
        const cells: usize = @intCast(g.cols * g.rows);
        if (self.cells.len != cells) self.cells = try self.allocator.realloc(self.cells, cells);
        if (self.out.len != frame.width * frame.height * 4) self.out = try self.allocator.realloc(self.out, frame.width * frame.height * 4);
        self.width = frame.width;
        self.height = frame.height;
        inline for (.{ Pass.field, Pass.cells, Pass.glyphs }) |pass| {
            const rows = switch (pass) {
                .field => fh,
                .cells => @as(usize, @intCast(g.rows)),
                .glyphs => frame.height,
            };
            if (parallel) {
                var group: std.Thread.WaitGroup = .{};
                const bands = 4 * (self.pool.threads.len + 1);
                for (0..bands) |band| self.pool.spawnWg(&group, rowsOf, .{ self, pass, frame, band, bands, rows });
                self.pool.waitAndWork(&group);
            } else rowsOf(self, pass, frame, 0, 1, rows);
        }
    }

    /// Works out every `bands`th row of a pass, from `band`.
    fn rowsOf(self: *Renderer, comptime pass: Pass, frame: *const Frame, band: usize, bands: usize, rows: usize) void {
        const g = frame.grid;
        var y = band;
        while (y < rows) : (y += bands) switch (pass) {
            .field => for (0..self.field.width) |x| {
                self.field.data[(y * self.field.width + x) * 4 ..][0..4].* = windAt(frame, x, y);
            },
            .cells => for (0..@as(usize, @intCast(g.cols))) |x| {
                self.cells[y * @as(usize, @intCast(g.cols)) + x] = cellOf(frame, &self.field, @intCast(x), @intCast(y));
            },
            .glyphs => for (0..frame.width) |x| {
                const gx = @as(i32, @intCast(x)) - g.left;
                const gy = @as(i32, @intCast(y)) - g.top;
                const i = (y * frame.width + x) * 4;
                const cx = @divFloor(gx, g.cell_w);
                const cy = @divFloor(gy, g.cell_h);
                var color: [4]f32 = @splat(0);
                if (gx >= 0 and gy >= 0 and cx < g.cols and cy < g.rows) {
                    const cell = self.cells[@intCast(cy * g.cols + cx)];
                    if (!cell.empty) color = glyphAt(frame, &self.field, cell, gx, gy);
                }
                self.out[i] = @intFromFloat(@round(std.math.clamp(color[2], 0, 1) * 255));
                self.out[i + 1] = @intFromFloat(@round(std.math.clamp(color[1], 0, 1) * 255));
                self.out[i + 2] = @intFromFloat(@round(std.math.clamp(color[0], 0, 1) * 255));
                self.out[i + 3] = @intFromFloat(@round(std.math.clamp(color[3], 0, 1) * 255));
            },
        };
    }
};

// The clock: a frame every frame_time, or ripple_time while a click's blow
// runs out; the wind blows for budget seconds after the last thing the
// user did and settles over settle_time, gathers speed again over
// resume_time, and the texture comes in over reveal_time seconds of wind
// and fades in over fade_time.
const frame_time = 40 * std.time.ns_per_ms;
const ripple_time = 10 * std.time.ns_per_ms;
const budget = 180;
const settle_time = 8;
const resume_time = 3;
const reveal_time = 4;
const fade_time = 3 * std.time.ns_per_s;
/// How strong the texture shows: its light is drawn headroom times weaker,
/// leaving room for the ripples' color above it.
const texture_strength = 0.26;

/// The glyphs a pane shows, blown by a wind.
const Texture = struct {
    wind: Wind,
    /// The looks of the last visits, latest first.
    recent: [3]usize = undefined,
    recent_len: usize = 0,
    hand: Hand = .{},
    /// The clock, in nanoseconds: when the texture started, which the
    /// hand's times count from, its last step, and when it first showed.
    start: ?u64 = null,
    last: ?u64 = null,
    shown: ?u64 = null,
    /// The wind's time; the seconds the texture moved; when it last began
    /// to come in, when the wind last resumed, and until when it blows;
    /// calm that it has settled.
    wind_time: f64 = 0,
    active: f64 = 0,
    reveal_from: f64 = 0,
    resumed_at: f64 = 0,
    until: f64 = budget,
    energy: f64 = 1,
    calm: bool = false,
    /// While the desktop asks for less motion, the texture shows the wind
    /// as it stands.
    still: bool = false,

    fn init(seed: u32) Texture {
        var self: Texture = .{ .wind = undefined };
        self.reseed(seed);
        return self;
    }

    /// Starts a new visit, with the wind of seed, in a look the last visits
    /// did not show.
    fn reseed(self: *Texture, seed: u32) void {
        const look = pickLook(seed, self.recent[0..self.recent_len]);
        var i: usize = @min(self.recent_len, self.recent.len - 1);
        while (i > 0) : (i -= 1) self.recent[i] = self.recent[i - 1];
        self.recent[0] = look;
        self.recent_len = @min(self.recent_len + 1, self.recent.len);
        self.wind = .init(seed, look);
        self.wind_time = @as(f64, @floatFromInt(seed)) / 4294967296 * 64;
        self.active = 0;
        self.reveal_from = 0;
        self.resumed_at = -resume_time;
        self.until = budget;
        self.energy = 1;
        self.calm = false;
        self.last = null;
        self.shown = null;
        self.hand = .{};
    }

    /// The seconds since the texture started, as the hand counts them.
    fn clock(self: *Texture, now: u64) f32 {
        if (self.start == null) self.start = now;
        return @floatCast(@as(f64, @floatFromInt(now -| self.start.?)) / std.time.ns_per_s);
    }

    /// The wind blows again for its whole budget, after the user did
    /// something: settled, it comes in anew.
    fn wake(self: *Texture) void {
        if (self.calm) {
            self.calm = false;
            self.reveal_from = self.active;
            self.resumed_at = self.active;
            self.until = self.active + budget;
            self.last = null;
        } else if (self.active < self.until) self.until = self.active + budget;
    }

    /// The pointer moved, or clicked, at (x, y) in the pane, in DIPs.
    fn move(self: *Texture, x: f32, y: f32, now: u64) void {
        if (self.still) return;
        self.hand.move(x, y, self.clock(now));
        self.wake();
    }
    fn tap(self: *Texture, x: f32, y: f32, now: u64) void {
        if (self.still) return;
        self.hand.tap(x, y, self.clock(now));
        self.wake();
    }

    /// Moves the clock to `now`: the wind blows as long as its budget
    /// lasts, then settles, the texture fading with it.
    fn step(self: *Texture, now: u64) void {
        var dt: f64 = 0;
        if (self.last) |last| dt = @min(@as(f64, @floatFromInt(now -| last)) / std.time.ns_per_s, 0.25);
        self.last = now;
        self.active += dt;
        self.energy = 1 - smooth((self.active - self.until) / settle_time);
        const speed = smooth((self.active - self.resumed_at) / resume_time);
        self.wind_time += dt * self.energy * speed;
    }

    fn moving(self: *const Texture) bool {
        return !self.still and !self.calm;
    }

    /// The time between frames at `now`.
    fn interval(self: *Texture, now: u64) u64 {
        return if (self.hand.rippling(self.clock(now))) ripple_time else frame_time;
    }

    /// The uniforms of a frame of grid g in a pane of w×h DIPs, at `now`.
    fn frame(self: *Texture, g: Grid, atlas: *const Atlas, w: f32, h: f32, dark: bool, now: u64) Frame {
        var reveal: f32 = @floatCast(smooth((self.active - self.reveal_from) / reveal_time) * self.energy);
        if (self.still) {
            reveal = 1;
            self.hand = .{};
        }
        self.hand.frame(self.clock(now));
        const k = 1 / g.scale;
        const wt: f32 = @floatCast(self.wind_time);
        const cw = @as(f32, @floatFromInt(g.cols * g.cell_w)) * k;
        const ch = @as(f32, @floatFromInt(g.rows * g.cell_h)) * k;
        // The texture fades in with the pane holding it.
        if (self.shown == null) self.shown = now;
        var fade: f32 = 1;
        const since = now -| self.shown.?;
        if (since < fade_time) {
            const e = easeOut(@as(f32, @floatFromInt(since)) / fade_time);
            fade = e * e;
        }
        var f: Frame = .{
            .seed = self.wind.seed,
            .time = wt,
            .reveal = reveal,
            .heading = .{ @cos(self.wind.heading), @sin(self.wind.heading) },
            .carried = self.wind.carried(wt),
            .span = self.wind.span(cw, ch),
            .gust_length = self.wind.gust_length,
            .gust_width = self.wind.gust_width,
            .bend = self.wind.bend,
            .bend_scale = self.wind.bend_scale,
            .pane = .{ w, h },
            .origin = .{ @as(f32, @floatFromInt(g.left)) * k, @as(f32, @floatFromInt(g.top)) * k },
            .step = .{ @as(f32, @floatFromInt(g.cell_w)) * k, @as(f32, @floatFromInt(g.cell_h)) * k / 2 },
            .now = self.hand.now,
            .grid = g,
            .atlas = atlas,
            .glow = if (dark) glow_dark else glow_light,
            .opacity = @min(1, texture_strength * headroom) * fade,
            .width = @intFromFloat(@max(1, @round(w * g.scale))),
            .height = @intFromFloat(@max(1, @round(h * g.scale))),
        };
        for (self.hand.taps.constSlice()) |blow| {
            f.taps[f.tap_count] = blow;
            f.tap_count += 1;
        }
        for (self.hand.warm.constSlice()) |warm| {
            f.warm[f.warm_count] = warm;
            f.warm_count += 1;
        }
        f.seq_len = atlas.sequence(self.wind.look, &f.seq).len;
        return f;
    }

    fn fading(self: *const Texture, now: u64) bool {
        return if (self.shown) |shown| now -| shown < fade_time + frame_time else true;
    }
};

fn smooth(x: f64) f64 {
    const k = std.math.clamp(x, 0, 1);
    return k * k * (3 - 2 * k);
}

/// CSS's ease-out: the cubic Bézier through (0, 0) and (1, 1) whose
/// handles lie at (0, 0) and (0.58, 1).
fn easeOut(x: f32) f32 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    // Find the curve's parameter at x by halving, then read its y there.
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..24) |_| {
        const u = (lo + hi) / 2;
        if (3 * (1 - u) * u * u * 0.58 + u * u * u < x) lo = u else hi = u;
    }
    const u = (lo + hi) / 2;
    return 3 * (1 - u) * u * u + u * u * u;
}

/// The window's state: the texture, and the draft in the composer.
const App = struct {
    allocator: std.mem.Allocator,
    texture: Texture,
    rng: std.Random.DefaultPrng,
    host: ?*view.Host = null,
    engine: ?*t.Engine = null,
    renderer: Renderer,
    /// The atlases drawn so far, which frames being drawn may read; one is
    /// being drawn.
    atlases: std.ArrayList(*Atlas) = .empty,
    atlas_queued: bool = false,
    image: ?ui.PixelImage = null,
    /// A frame is being drawn; the frame asked for last, and whether the
    /// texture moved since.
    busy: bool = false,
    next: ?Frame = null,
    /// The pane's size in DIPs, its pixels per DIP, and whether its theme
    /// is dark.
    width: f32 = window_width,
    height: f32 = window_height,
    scale: f32 = 1,
    dark: bool = false,
    /// The leaves that take the pointer around the composer, and where
    /// they lie.
    airs: [4]Air = undefined,
    composer: ?*Composer = null,

    fn init(allocator: std.mem.Allocator, seed: u32) App {
        var self: App = .{ .allocator = allocator, .texture = .init(seed), .rng = .init(seed), .renderer = .{ .allocator = allocator } };
        for (&self.airs) |*air| air.* = .{};
        return self;
    }

    fn deinit(self: *App) void {
        self.renderer.stop();
        for (self.atlases.items) |atlas| atlas.deinit(self.allocator);
        self.atlases.deinit(self.allocator);
        if (self.image) |*image| image.deinit();
    }

    fn build(self: *App, v: *view.View) anyerror!void {
        const now = v.time();
        const tex = &self.texture;
        // While the desktop asks for less motion, the texture shows the
        // wind as it stands.
        if (tex.still != v.preferences.reduce_motion) {
            tex.still = v.preferences.reduce_motion;
            self.next = null;
        }
        try v.bindKey(.{ .key = .r, .modifiers = .{ .control = true } }, true, 1);
        if (v.takeEvent(1) != null) {
            tex.reseed(self.rng.random().int(u32));
            self.next = null;
        }
        if (tex.moving()) {
            tex.step(now);
            self.next = null;
            if (tex.energy == 0 and !tex.hand.busy(tex.clock(now))) tex.calm = true;
            v.wakeAt(now + tex.interval(now));
        } else if (tex.fading(now)) {
            self.next = null;
            v.wakeAt(now + frame_time);
        }

        try v.column(.{ .grow = 1, .self_align = .stretch });
        // The texture, behind everything.
        try v.embed(.{ .context = self, .measure = Picture.measure, .paint = Picture.paint }, .{ .key = 2 });
        // The pointer stirs the air wherever it is over the pane, but for
        // the composer, which takes it itself. The card's middle lies where
        // the texture is calmest, 45% down.
        try v.embed(self.airs[0].embed(self), .{ .key = 3, .grow = 45, .self_align = .stretch });
        try v.row(.{ .self_align = .stretch });
        try v.embed(self.airs[1].embed(self), .{ .key = 4, .grow = 1, .self_align = .stretch });
        try v.column(.{ .width = @min(640, self.width - 48), .gap = 12 });
        try v.row(.{ .padding = .{ .top = 12, .bottom = 12, .left = 16, .right = 16 }, .radius = 14, .background = if (self.dark) 0x242b33 else 0xffffff, .border = if (self.dark) 0x394049 else 0xe6e4df, .alignment = .center });
        if (self.composer) |composer| try v.embed(composer.embed(), .{ .key = 5, .grow = 1 }) else try v.spacer(.{});
        try v.end();
        try v.text("Move the pointer to warm the air, click to blow a ripple (every third a heart), Ctrl+R for another wind.", .{ .font = .{ .size = 12 }, .color = 0x8e8b85, .self_align = .center });
        try v.end();
        try v.embed(self.airs[2].embed(self), .{ .key = 6, .grow = 1, .self_align = .stretch });
        try v.end();
        try v.embed(self.airs[3].embed(self), .{ .key = 7, .grow = 55, .self_align = .stretch });
        try v.row(.{ .self_align = .end, .padding = .{ .right = 14, .bottom = 10 } });
        var label: [32]u8 = undefined;
        try v.text(try std.fmt.bufPrint(&label, "{s}/{x:0>8}", .{ looks[tex.wind.look].name, tex.wind.seed }), .{ .font = .{ .size = 11, .monospace = true }, .color = 0x8e8b85, .min_width = 130 });
        try v.end();
        try v.end();
    }

    /// The draft changed: typing keeps the wind blowing.
    fn changed(ptr: ?*anyopaque, _: z.Window, _: u64) void {
        const self: *App = @ptrCast(@alignCast(ptr.?));
        self.texture.wake();
        if (self.composer) |composer| composer.update();
        if (self.host) |host| if (host.context.window) |window| window.invalidate();
    }

    fn time(self: *App) u64 {
        const host = self.host orelse return 0;
        return host.time();
    }

    /// Asks for the next frame unless one is being drawn or the picture
    /// already shows the texture as it stands.
    fn ask(self: *App) void {
        if (self.busy or self.renderer.thread == null) return;
        if (self.next != null and self.image != null) return;
        const w: i32 = @intFromFloat(@round(self.width * self.scale));
        const h: i32 = @intFromFloat(@round(self.height * self.scale));
        const g = Grid.of(w, h, self.scale) orelse return;
        const atlas = self.atlasFor(g) orelse return;
        const frame = self.texture.frame(g, atlas, self.width, self.height, self.dark, self.time());
        self.next = frame;
        self.busy = true;
        self.renderer.ask(frame);
    }

    /// The atlas for grid g, or null while it is being drawn.
    fn atlasFor(self: *App, g: Grid) ?*const Atlas {
        for (self.atlases.items) |atlas| if (atlas.cell_w == g.cell_w and atlas.scale == g.scale) return atlas;
        if (self.atlas_queued) return null;
        const host = self.host orelse return null;
        const window = host.context.window orelse return null;
        window.app.post(.{ .context = self, .call = drawAtlas }) catch return null;
        self.atlas_queued = true;
        return null;
    }

    /// Draws the atlas the pane needs, outside paint.
    fn drawAtlas(ptr: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ptr));
        self.atlas_queued = false;
        const engine = self.engine orelse return;
        const cell_w: i32 = @max(5, @as(i32, @intFromFloat(@round(cell_size * self.scale))));
        const atlas = Atlas.init(self.allocator, engine, cell_w, self.scale) catch |err| return std.log.err("wind: atlas: {s}", .{@errorName(err)});
        self.atlases.append(self.allocator, atlas) catch return atlas.deinit(self.allocator);
        if (self.host) |host| if (host.context.window) |window| window.invalidate();
    }

    /// On the drawing thread: the frame is done.
    fn drawn(renderer: *Renderer) void {
        const self: *App = @alignCast(@fieldParentPtr("renderer", renderer));
        const host = self.host orelse return;
        const window = host.context.window orelse return;
        window.app.post(.{ .context = self, .call = show }) catch {};
    }

    /// Shows the frame just drawn.
    fn show(ptr: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ptr));
        self.busy = false;
        const host = self.host orelse return;
        const window = host.context.window orelse return;
        const renderer = &self.renderer;
        const width: u32 = @intCast(renderer.width);
        const height: u32 = @intCast(renderer.height);
        if (self.image) |*image| if (image.width != width or image.height != height) {
            image.release(&host.context);
            image.deinit();
            self.image = null;
        };
        if (self.image == null) self.image = ui.PixelImage.init(self.allocator, width, height) catch return;
        const image = &self.image.?;
        @memcpy(image.pixels(), renderer.out);
        image.commit(&host.context) catch |err| std.log.err("wind: {s}", .{@errorName(err)});
        window.invalidate();
    }
};

/// The leaf of no size that draws the texture over the pane, behind
/// everything else.
const Picture = struct {
    fn measure(ptr: *anyopaque, theme: ui.Theme) view.layout.Measurement {
        const self: *App = @ptrCast(@alignCast(ptr));
        const bg = theme.palette.background;
        const luma = 0.3 * @as(f32, @floatFromInt(bg >> 16 & 0xff)) + 0.59 * @as(f32, @floatFromInt(bg >> 8 & 0xff)) + 0.11 * @as(f32, @floatFromInt(bg & 0xff));
        const dark = luma < 128;
        if (dark != self.dark) self.next = null;
        self.dark = dark;
        return .{ .minimum = .{ .width = 0, .height = 0 }, .preferred = .{ .width = 0, .height = 0 } };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, _: u64, _: view.Rect) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ptr));
        const width = @as(f32, @floatFromInt(frame.size.width)) / frame.size.scale;
        const height = @as(f32, @floatFromInt(frame.size.height)) / frame.size.scale;
        if (width != self.width or height != self.height or frame.size.scale != self.scale) self.next = null;
        self.width = width;
        self.height = height;
        self.scale = frame.size.scale;
        if (self.image) |*image| if (image.view()) |picture| try frame.image(.{ .x = 0, .y = 0, .width = width, .height = height }, picture, .{});
        self.ask();
    }
};

/// A leaf over the pane that takes the pointer: its moves warm the air and
/// its clicks blow ripples.
const Air = struct {
    app: *App = undefined,
    origin: view.Point = .{},

    fn embed(self: *Air, app: *App) view.Embed {
        self.app = app;
        return .{ .context = self, .measure = measure, .place = place, .paint = paint, .input = input };
    }
    fn measure(_: *anyopaque, _: ui.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 0, .height = 0 }, .preferred = .{ .width = 0, .height = 0 } };
    }
    fn place(ptr: *anyopaque, _: u64, bounds: view.Rect) void {
        const self: *Air = @ptrCast(@alignCast(ptr));
        self.origin = .{ .x = bounds.x, .y = bounds.y };
    }
    fn paint(_: *anyopaque, _: *ui.Frame, _: u64, _: view.Rect) anyerror!void {}
    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *Air = @ptrCast(@alignCast(ptr));
        const tex = &self.app.texture;
        const now = self.app.time();
        switch (event) {
            .pointer_move => |p| {
                const calm = tex.calm;
                tex.move(self.origin.x + p.x, self.origin.y + p.y, now);
                // A frame, to wake the texture as it rests.
                return calm;
            },
            .pointer_drag => |p| tex.move(self.origin.x + p.position.x, self.origin.y + p.position.y, now),
            .pointer_down => |p| tex.tap(self.origin.x + p.position.x, self.origin.y + p.position.y, now),
            .pointer_up, .pointer_cancel => {},
            else => return false,
        }
        return true;
    }
};

/// The composer: a text field that shows a placeholder while empty.
const Composer = struct {
    field: text.TextField,
    empty: bool = true,

    fn embed(self: *Composer) view.Embed {
        var e = self.field.embed();
        inner_paint = e.paint;
        e.paint = paint;
        return e;
    }

    var inner_paint: *const fn (*anyopaque, *ui.Frame, u64, view.Rect) anyerror!void = undefined;

    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: view.Rect) anyerror!void {
        const field: *text.TextField = @ptrCast(@alignCast(ptr));
        const self: *Composer = @alignCast(@fieldParentPtr("field", field));
        try inner_paint(ptr, frame, id, bounds);
        if (self.empty) frame.labelFont(.{ .x = bounds.x + 4, .y = bounds.y, .width = bounds.width - 8, .height = bounds.height }, "Describe a task or ask a question", 0x9b9892, .{ .size = 15 });
    }

    fn update(self: *Composer) void {
        self.empty = (self.field.field.document.byteLength() catch 0) == 0;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app_state: App = .init(allocator, std.crypto.random.int(u32));
    defer app_state.deinit();
    var storage: view.Storage(128, 4096) = .{};
    var host = view.Host.init(&app_state, App.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0) } });
    app_state.host = &host;
    var timer = view_timer.Timer.init(&host);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch {};
    app_state.engine = engine;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "", .{});
    defer document.close() catch {};

    const window = try app.createWindow(.{ .title = "Wind", .width = window_width, .height = window_height });
    try host.attach(window);
    try host.context.prepareTextFields(allocator, .{});
    try timer.attach(app, allocator);
    const field = try editing.Field.create(allocator, document, engine, .{ .value_bytes = 4096, .context = &app_state, .changed = App.changed });
    var composer: Composer = .{ .field = text.TextField.init(field, &host, .{ .font = .{ .size = 15 }, .scale = (try window.contentSize()).scale }, .{ .name = "Task", .frame = false }) };
    app_state.composer = &composer;
    app_state.renderer.done = App.drawn;
    try app_state.renderer.start();

    window.show();
    try app.run();
    app_state.renderer.stop();
    app_state.composer = null;
    composer.field.detach();
    try field.close();
    for (app_state.atlases.items) |atlas| atlas.deinit(allocator);
    app_state.atlases.clearRetainingCapacity();
    app_state.engine = null;
    try timer.close();
    app_state.host = null;
}

test "the grid's cells are 6.5 DIPs wide, in whole pixels, twice as high, centered and overhanging" {
    const g = Grid.of(2200, 1440, 2).?;
    try std.testing.expectEqual(@as(i32, 13), g.cell_w);
    try std.testing.expectEqual(@as(i32, 26), g.cell_h);
    try std.testing.expectEqual(@as(i32, 170), g.cols);
    try std.testing.expectEqual(@as(i32, 56), g.rows);
    try std.testing.expectEqual(@as(i32, -5), g.left);
    try std.testing.expectEqual(@as(i32, -8), g.top);
    try std.testing.expectEqual(@as(i32, 7), Grid.of(1100, 720, 1).?.cell_w);
    try std.testing.expect(Grid.of(100, 100, 1) == null);
}

test "a seed picks the same wind every time, heading down the pane, in a look the last visits did not show" {
    try std.testing.expectEqual(Wind.init(42, 0), Wind.init(42, 0));
    for (0..200) |i| {
        const seed: u32 = @intCast(i);
        const w = Wind.init(seed, 0);
        try std.testing.expect(w.heading > 0 and w.heading < 3.1416 and w.speed >= 42 and w.speed <= 64 and w.gust_width >= 120 and w.gust_width <= 190);
        try std.testing.expectEqual(@as(usize, 1), pickLook(seed, &.{ 0, 2 }));
        try std.testing.expect(pickLook(seed, &.{ 0, 2, 1 }) != 0);
    }
}

test "clicks on the pane blow ripples, every third a heart; the composer blows none" {
    var app_state: App = .init(std.testing.allocator, 7);
    defer app_state.deinit();
    var storage: view.Storage(128, 4096) = .{};
    var h = view.Harness.init(&app_state, App.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = window_width, .height = window_height }, .options = .{ .root = .{ .padding = view.Insets.all(0) } } });
    try h.render();
    for (0..3) |i| {
        try h.clickAt(100 + @as(f32, @floatFromInt(i)) * 50, 120);
        try h.render();
    }
    const taps = app_state.texture.hand.taps.constSlice();
    try std.testing.expectEqual(@as(usize, 3), taps.len);
    try std.testing.expectEqual(@as(f32, 100), taps[0].x);
    try std.testing.expectEqual(@as(f32, 120), taps[0].y);
    try std.testing.expect(taps[0].force > 0 and taps[1].force > 0 and taps[2].force < 0);
    // The composer's card lies 45% down the middle, where no air takes the
    // press.
    try std.testing.expectError(error.NotFound, h.clickAt(window_width / 2, window_height * 0.45 - 8));
    try std.testing.expectEqual(@as(usize, 3), app_state.texture.hand.taps.len);
    var label: [32]u8 = undefined;
    _ = try h.find(.{ .text = try std.fmt.bufPrint(&label, "{s}/00000007", .{looks[app_state.texture.wind.look].name}) });
}

test "the wind blows for its budget, settles and fades out; the next move brings it back" {
    var tex: Texture = .init(7);
    var now: u64 = 1000 * std.time.ns_per_s;
    for (0..(budget + settle_time + 1) * 25) |_| {
        now += 40 * std.time.ns_per_ms;
        tex.step(now);
    }
    try std.testing.expectEqual(@as(f64, 0), tex.energy);
    const frozen = tex.wind_time;
    tex.step(now + std.time.ns_per_s);
    try std.testing.expectEqual(frozen, tex.wind_time);
    tex.calm = true;
    tex.move(10, 10, now);
    try std.testing.expect(!tex.calm and tex.reveal_from == tex.active and tex.until == tex.active + budget);
}

/// Draws a still texture in a pane of 300×200 DIPs at 1, and counts the
/// pixels in the plain ink and those in the ripples' tint.
fn renderStill(click: bool, energy: f64, still: bool) ![2]usize {
    const allocator = std.testing.allocator;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch {};
    const atlas = try Atlas.init(allocator, engine, 7, 1);
    defer atlas.deinit(allocator);
    var tex: Texture = .init(0x3fa1c2d9);
    tex.wind_time = 21.5;
    tex.calm = true;
    tex.active = 10;
    tex.energy = energy;
    tex.still = still;
    tex.start = 0;
    tex.shown = 0;
    const now = 3600 * std.time.ns_per_s;
    if (click) {
        tex.start = now - std.time.ns_per_s;
        tex.hand.tap(150, 100, 0);
    }
    const frame = tex.frame(Grid.of(300, 200, 1).?, atlas, 300, 200, false, now);
    var renderer: Renderer = .{ .allocator = allocator };
    defer renderer.stop();
    try renderer.draw(&frame, false);
    var counts: [2]usize = .{ 0, 0 };
    var i: usize = 0;
    while (i < renderer.out.len) : (i += 4) {
        const b = renderer.out[i];
        const r = renderer.out[i + 2];
        const a = renderer.out[i + 3];
        if (a == 0) continue;
        if (@as(u32, b) > @as(u32, r) + 20) counts[1] += 1 else counts[0] += 1;
    }
    return counts;
}

test "glyphs show in the plain ink where the wind blows, and a click's ripple tints those its front reaches" {
    const plain = try renderStill(false, 1, false);
    try std.testing.expect(plain[0] > 0 and plain[1] == 0);
    const clicked = try renderStill(true, 1, false);
    try std.testing.expect(clicked[1] > 0);
}

test "settled, the texture has faded out; asking for less motion shows the wind as it stands" {
    const settled = try renderStill(false, 0, false);
    try std.testing.expectEqual(@as(usize, 0), settled[0] + settled[1]);
    const still = try renderStill(false, 0, true);
    try std.testing.expect(still[0] > 0);
}

test "a heart is a circle across and not up and down alike; ease-out slows into its end" {
    try std.testing.expectApproxEqAbs(@as(f32, 1), heart(1, 0), 1e-4);
    try std.testing.expect(heart(0.7071, 0.7071) != heart(0.7071, -0.7071));
    // Ease-out rises quickly and slows into its end.
    try std.testing.expect(easeOut(0.5) > 0.6 and easeOut(0.5) < 0.9);
}
