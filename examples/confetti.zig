//! Confetti in native UI, as canvas-confetti throws it on a web page:
//! bursts of squares, circles, stars, hearts and emoji that fly out, slow
//! down, fall, tumble and fade.
//!
//! Pick one of canvas-confetti's demos, or click the stage to throw a burst
//! of your own from the pointer. The pieces move as canvas-confetti moves
//! them, one tick a sixtieth of a second, and are drawn on the CPU into a
//! `ui.PixelImage` that covers the window: a leaf of no size, built last,
//! paints it over everything and lets the pointer through.
//!
//! Run it with `zig build run-confetti`.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");

const window_width = 980;
const window_height = 700;
const muted: u32 = 0x5f6b7a;
const border: u32 = 0xd5dbe3;
const surface: u32 = 0xffffff;

/// How long canvas-confetti moves its pieces once.
const tick: u64 = std.time.ns_per_s / 60;

/// How many pieces can be in the air: a button pressed again and again
/// lets the oldest, most faded pieces go first.
const max_pieces = 1500;

pub const Shape = union(enum) {
    square,
    circle,
    star,
    heart,
    /// An emoji.
    text: []const u8,
};

/// How a burst of confetti flies, as canvas-confetti's options: speeds and
/// distances are in DIPs per tick.
pub const Options = struct {
    count: u32 = 50,
    /// Direction in degrees counterclockwise from the right (90 is up), and
    /// how far the pieces stray from it.
    angle: f64 = 90,
    spread: f64 = 45,
    /// A piece starts from half to one and a half times this fast; its
    /// speed keeps `decay` of itself every tick.
    start_velocity: f64 = 45,
    decay: f64 = 0.9,
    /// Pulls the pieces down 3 DIPs every tick, times this; drift moves
    /// them sideways.
    gravity: f64 = 1,
    drift: f64 = 0,
    /// How long the pieces last, fading as they go.
    ticks: u32 = 200,
    /// Where the burst starts, as fractions of the window's size.
    x: f64 = 0.5,
    y: f64 = 0.5,
    colors: []const u32 = &default_colors,
    shapes: []const Shape = &.{ .square, .circle },
    scalar: f64 = 1,
    /// Keeps the pieces facing the viewer instead of tumbling.
    flat: bool = false,
};

/// canvas-confetti's colors.
const default_colors = [_]u32{ 0x26ccff, 0xa25afd, 0xff5e7e, 0x88ff5a, 0xfcff42, 0xffa62d, 0xff36ff };

/// A piece of confetti, as canvas-confetti keeps it.
const Piece = struct {
    x: f64,
    y: f64,
    wobble: f64,
    wobble_speed: f64,
    velocity: f64,
    angle: f64,
    tilt_angle: f64,
    color: u32,
    shape: Shape,
    tick: u32 = 0,
    total_ticks: u32,
    decay: f64,
    drift: f64,
    random: f64,
    tilt_sin: f64 = 0,
    tilt_cos: f64 = 0,
    wobble_x: f64 = 0,
    wobble_y: f64 = 0,
    gravity: f64,
    scalar: f64,
    flat: bool,

    /// Moves the piece one tick; false once it faded away.
    fn update(self: *Piece, random: std.Random) bool {
        self.x += @cos(self.angle) * self.velocity + self.drift;
        self.y += @sin(self.angle) * self.velocity + self.gravity;
        self.velocity *= self.decay;
        if (self.flat) {
            self.wobble = 0;
            self.wobble_x = self.x + 10 * self.scalar;
            self.wobble_y = self.y + 10 * self.scalar;
            self.tilt_sin = 0;
            self.tilt_cos = 0;
            self.random = 1;
        } else {
            self.wobble += self.wobble_speed;
            self.wobble_x = self.x + 10 * self.scalar * @cos(self.wobble);
            self.wobble_y = self.y + 10 * self.scalar * @sin(self.wobble);
            self.tilt_angle += 0.1;
            self.tilt_sin = @sin(self.tilt_angle);
            self.tilt_cos = @cos(self.tilt_angle);
            self.random = random.float(f64) + 2;
        }
        self.tick += 1;
        return self.tick < self.total_ticks;
    }

    fn alpha(self: *const Piece) f64 {
        return 1 - @as(f64, @floatFromInt(self.tick)) / @as(f64, @floatFromInt(self.total_ticks));
    }
};

/// A demo that throws confetti for a while: `fire` runs `count` times,
/// `every` apart.
const Emitter = struct {
    preset: usize,
    next: u64,
    every: u64,
    index: u32,
    count: u32,
};

const Preset = struct {
    name: []const u8,
    about: []const u8,
    /// Throws the demo's confetti, or its `index`th round of `count`.
    fire: *const fn (*Confetti, u32, u32) void,
    /// Rounds and their spacing for demos that last.
    rounds: u32 = 1,
    every: u64 = 0,
};

const presets = [_]Preset{
    .{ .name = "Basic Cannon", .about = "One burst, up from below", .fire = basicCannon },
    .{ .name = "Random Direction", .about = "Another angle every time", .fire = randomDirection },
    .{ .name = "Realistic Look", .about = "Five bursts, fast to slow", .fire = realisticLook },
    .{ .name = "Fireworks", .about = "Bursts all around for 5 s", .fire = fireworks, .rounds = 20, .every = 250 * std.time.ns_per_ms },
    .{ .name = "Stars", .about = "Golden stars floating out", .fire = stars, .rounds = 3, .every = 100 * std.time.ns_per_ms },
    .{ .name = "Snow", .about = "Flakes drifting down for 8 s", .fire = snow, .rounds = 270, .every = 30 * std.time.ns_per_ms },
    .{ .name = "School Pride", .about = "Cannons from both sides", .fire = schoolPride, .rounds = 160, .every = 25 * std.time.ns_per_ms },
    .{ .name = "Emoji", .about = "Unicorns and rainbows", .fire = emoji, .rounds = 3, .every = 100 * std.time.ns_per_ms },
    .{ .name = "Hearts", .about = "A shape drawn as a path", .fire = hearts, .rounds = 3, .every = 100 * std.time.ns_per_ms },
};

fn basicCannon(s: *Confetti, _: u32, _: u32) void {
    s.burst(.{ .count = 100, .spread = 70, .y = 0.6 });
}
fn randomDirection(s: *Confetti, _: u32, _: u32) void {
    const r = s.rng.random();
    s.burst(.{ .angle = 55 + r.float(f64) * 70, .spread = 50 + r.float(f64) * 20, .count = 50 + r.uintLessThan(u32, 50), .y = 0.6 });
}
fn realisticLook(s: *Confetti, _: u32, _: u32) void {
    const total = 200.0;
    s.burst(.{ .count = @intFromFloat(total * 0.25), .y = 0.7, .spread = 26, .start_velocity = 55 });
    s.burst(.{ .count = @intFromFloat(total * 0.2), .y = 0.7, .spread = 60 });
    s.burst(.{ .count = @intFromFloat(total * 0.35), .y = 0.7, .spread = 100, .decay = 0.91, .scalar = 0.8 });
    s.burst(.{ .count = @intFromFloat(total * 0.1), .y = 0.7, .spread = 120, .start_velocity = 25, .decay = 0.92, .scalar = 1.2 });
    s.burst(.{ .count = @intFromFloat(total * 0.1), .y = 0.7, .spread = 120, .start_velocity = 45 });
}
fn fireworks(s: *Confetti, i: u32, n: u32) void {
    const r = s.rng.random();
    for ([_][2]f64{ .{ 0.1, 0.3 }, .{ 0.7, 0.9 } }) |range| {
        s.burst(.{ .count = 50 * (n - i) / n, .start_velocity = 30, .spread = 360, .ticks = 60, .x = range[0] + r.float(f64) * (range[1] - range[0]), .y = r.float(f64) - 0.2 });
    }
}
const gold = [_]u32{ 0xffe400, 0xffbd00, 0xe89400, 0xffca6c, 0xfdffb8 };
fn stars(s: *Confetti, _: u32, _: u32) void {
    const base: Options = .{ .spread = 360, .ticks = 50, .gravity = 0, .decay = 0.94, .start_velocity = 30, .colors = &gold };
    var o = base;
    o.count = 40;
    o.scalar = 1.2;
    o.shapes = &.{.star};
    s.burst(o);
    o.count = 10;
    o.scalar = 0.75;
    o.shapes = &.{.circle};
    s.burst(o);
}
const snow_dark = [_]u32{ 0xffffff, 0xdbeafe, 0xbfdbfe };
const snow_light = [_]u32{ 0x93c5fd, 0xbfdbfe, 0xcbd5e1 };
fn snow(s: *Confetti, i: u32, n: u32) void {
    const r = s.rng.random();
    const left = @as(f64, @floatFromInt(n - i)) / @as(f64, @floatFromInt(n));
    s.skew = @max(0.8, s.skew - 0.001);
    s.burst(.{
        .count = 1,
        .start_velocity = 0,
        .shapes = &.{.circle},
        .ticks = @intFromFloat(@max(200, 500 * left)),
        .x = r.float(f64),
        .y = r.float(f64) * s.skew - 0.2,
        .colors = if (s.dark) &snow_dark else &snow_light,
        .gravity = 0.4 + r.float(f64) * 0.2,
        .scalar = 0.4 + r.float(f64) * 0.6,
        .drift = -0.4 + r.float(f64) * 0.8,
    });
}
const pride_dark = [_]u32{ 0xbb0000, 0xffffff };
const pride_light = [_]u32{ 0xbb0000, 0x1e293b };
fn schoolPride(s: *Confetti, _: u32, _: u32) void {
    const colors: []const u32 = if (s.dark) &pride_dark else &pride_light;
    s.burst(.{ .count = 2, .angle = 60, .spread = 55, .x = 0, .colors = colors });
    s.burst(.{ .count = 2, .angle = 120, .spread = 55, .x = 1, .colors = colors });
}
fn emoji(s: *Confetti, _: u32, _: u32) void {
    var o: Options = .{ .spread = 360, .ticks = 60, .gravity = 0, .decay = 0.96, .start_velocity = 20, .shapes = &.{ .{ .text = "🦄" }, .{ .text = "🌈" } }, .scalar = 2, .count = 30 };
    s.burst(o);
    o.count = 5;
    o.flat = true;
    s.burst(o);
    o.count = 15;
    o.flat = false;
    o.scalar = 1;
    o.shapes = &.{.circle};
    s.burst(o);
}
const pinks = [_]u32{ 0xff4d6d, 0xff758f, 0xc9184a, 0xffb3c1 };
fn hearts(s: *Confetti, _: u32, _: u32) void {
    s.burst(.{ .spread = 360, .ticks = 70, .gravity = 0.3, .decay = 0.95, .start_velocity = 25, .count = 25, .scalar = 1.5, .shapes = &.{.heart}, .flat = true, .colors = &pinks });
}

const Confetti = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    pieces: std.ArrayList(Piece) = .empty,
    emitters: std.ArrayList(Emitter) = .empty,
    /// The time the pieces were last moved to.
    moved: ?u64 = null,
    /// The window's size in DIPs as the last paint saw it.
    width: f32 = window_width,
    height: f32 = window_height,
    /// Whether the pieces should show on a dark background; the window
    /// keeps the light theme.
    dark: bool = false,
    skew: f64 = 1,
    /// The stage's options, as its sliders set them.
    count: f64 = 150,
    angle: f64 = 90,
    spread: f64 = 360,
    velocity: f64 = 30,
    decay: f64 = 0.9,
    gravity: f64 = 1,
    drift: f64 = 0,
    scalar: f64 = 1,
    stage: Stage = .{},
    layer: Layer = .{},

    fn init(allocator: std.mem.Allocator) Confetti {
        return .{ .allocator = allocator, .rng = .init(std.crypto.random.int(u64)) };
    }
    fn deinit(self: *Confetti) void {
        self.pieces.deinit(self.allocator);
        self.emitters.deinit(self.allocator);
        if (self.layer.image) |*image| image.deinit();
    }

    fn resetOptions(self: *Confetti) void {
        self.count = 150;
        self.angle = 90;
        self.spread = 360;
        self.velocity = 30;
        self.decay = 0.9;
        self.gravity = 1;
        self.drift = 0;
        self.scalar = 1;
    }

    /// Throws a burst as `o` says, as canvas-confetti makes its pieces.
    fn burst(self: *Confetti, o: Options) void {
        const r = self.rng.random();
        const rad_angle = o.angle * std.math.pi / 180;
        const rad_spread = o.spread * std.math.pi / 180;
        self.pieces.ensureUnusedCapacity(self.allocator, o.count) catch return;
        for (0..o.count) |_| {
            self.pieces.appendAssumeCapacity(.{
                .x = o.x * self.width,
                .y = o.y * self.height,
                .wobble = r.float(f64) * 10,
                .wobble_speed = @min(0.11, r.float(f64) * 0.1 + 0.05),
                .velocity = o.start_velocity * 0.5 + r.float(f64) * o.start_velocity,
                .angle = -rad_angle + (0.5 * rad_spread - r.float(f64) * rad_spread),
                .tilt_angle = (r.float(f64) * 0.5 + 0.25) * std.math.pi,
                .color = o.colors[r.uintLessThan(usize, o.colors.len)],
                .shape = o.shapes[r.uintLessThan(usize, o.shapes.len)],
                .total_ticks = @max(1, o.ticks),
                .decay = o.decay,
                .drift = o.drift,
                .random = r.float(f64) + 2,
                .gravity = o.gravity * 3,
                .scalar = o.scalar,
                .flat = o.flat,
            });
        }
        if (self.pieces.items.len > max_pieces) {
            const over = self.pieces.items.len - max_pieces;
            std.mem.copyForwards(Piece, self.pieces.items, self.pieces.items[over..]);
            self.pieces.shrinkRetainingCapacity(max_pieces);
        }
    }

    fn run(self: *Confetti, index: usize, now: u64) void {
        const preset = presets[index];
        preset.fire(self, 0, preset.rounds);
        if (preset.rounds > 1) self.emitters.append(self.allocator, .{ .preset = index, .next = now + preset.every, .every = preset.every, .index = 1, .count = preset.rounds }) catch {};
    }

    /// Moves the pieces to `now`, a tick at a time, and fires the demos
    /// whose time came.
    fn advance(self: *Confetti, now: u64, still: bool) void {
        var e: usize = 0;
        while (e < self.emitters.items.len) {
            const emitter = &self.emitters.items[e];
            while (emitter.index < emitter.count and now >= emitter.next) {
                if (!still) presets[emitter.preset].fire(self, emitter.index, emitter.count);
                emitter.index += 1;
                emitter.next += emitter.every;
            }
            if (emitter.index >= emitter.count) {
                _ = self.emitters.orderedRemove(e);
            } else e += 1;
        }
        const from = self.moved orelse now;
        var ticks = (now -| from) / tick;
        self.moved = from + ticks * tick;
        // After a long pause, as a window that was hidden, pieces jump.
        ticks = @min(ticks, 240);
        const r = self.rng.random();
        for (0..ticks) |_| {
            var kept: usize = 0;
            for (self.pieces.items) |*piece| {
                if (piece.update(r)) {
                    self.pieces.items[kept] = piece.*;
                    kept += 1;
                }
            }
            self.pieces.shrinkRetainingCapacity(kept);
            if (kept == 0) break;
        }
    }

    /// The stage's options for a burst from (x, y) in window DIPs.
    fn custom(self: *const Confetti, x: f32, y: f32) Options {
        return .{
            .count = @intFromFloat(self.count),
            .angle = self.angle,
            .spread = self.spread,
            .start_velocity = self.velocity,
            .decay = self.decay,
            .gravity = self.gravity,
            .drift = self.drift,
            .scalar = self.scalar,
            .x = x / self.width,
            .y = y / self.height,
        };
    }

    fn build(self: *Confetti, v: *view.View) anyerror!void {
        const now = v.time();
        // While the desktop asks for less motion, nothing flies: the pieces
        // would only show where they land, fading.
        const still = v.preferences.reduce_motion;
        self.advance(now, still);

        try v.column(.{ .grow = 1, .self_align = .stretch, .gap = 20 });
        try v.row(.{ .alignment = .end, .gap = 12, .self_align = .stretch });
        try v.column(.{ .gap = 4, .grow = 1 });
        try v.text("Confetti", .{ .font = .{ .size = 28, .weight = .bold } });
        try v.text("canvas-confetti's demos in native UI, every piece moved and drawn on the CPU.", .{ .color = muted });
        try v.end();
        try v.textf("{d} in the air", .{self.pieces.items.len}, .{ .color = muted, .font = .{ .size = 12 } });
        try v.end();
        if (still) try v.text("Confetti rests while the desktop asks for less motion.", .{ .color = 0xb45309 });

        try v.row(.{ .grow = 1, .gap = 16, .alignment = .stretch, .self_align = .stretch });
        try v.column(.{ .grow = 1, .gap = 16 });
        const columns = [_]view.Track{ .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 } };
        try v.grid(&columns, .{ .gap = 12, .self_align = .stretch });
        for (presets, 0..) |preset, i| {
            try v.column(.{ .key = 10 + i, .gap = 4, .padding = .{ .top = 10, .bottom = 10, .left = 12, .right = 12 }, .radius = 10, .border = border, .background = surface, .self_align = .stretch });
            if (try v.button(preset.name, .{ .self_align = .stretch }) and !still) self.run(i, now);
            try v.text(preset.about, .{ .color = muted, .font = .{ .size = 12 } });
            try v.end();
        }
        try v.end();
        self.stage.owner = self;
        self.stage.still = still;
        try v.embed(self.stage.embed(), .{ .grow = 1, .self_align = .stretch, .key = 2, .name = "Stage" });
        try v.end();
        try self.controls(v);
        try v.end();
        try v.end();

        // The pieces fly over everything, from a leaf built last.
        self.layer.owner = self;
        try v.embed(self.layer.embed(), .{ .key = 3 });
        // Demos that throw more need another pass; flying pieces repaint
        // through the layer.
        for (self.emitters.items) |emitter| v.wakeAt(emitter.next);
        if (self.pieces.items.len > 0) v.wakeAt(now + tick);
    }

    /// The sliders of the stage's bursts.
    fn controls(self: *Confetti, v: *view.View) !void {
        try v.column(.{ .width = 280, .gap = 10, .padding = view.Insets.all(16), .radius = 12, .background = surface, .border = border });
        try v.text("Your burst", .{ .font = .{ .size = 14, .weight = .bold } });
        try slider(v, "Count", &self.count, 1, 400, 1, "{d:.0}");
        try slider(v, "Angle", &self.angle, 0, 360, 1, "{d:.0}°");
        try slider(v, "Spread", &self.spread, 0, 360, 1, "{d:.0}°");
        try slider(v, "Velocity", &self.velocity, 0, 90, 1, "{d:.0}");
        try slider(v, "Decay", &self.decay, 0.8, 0.99, 0.01, "{d:.2}");
        try slider(v, "Gravity", &self.gravity, -1, 3, 0.1, "{d:.1}");
        try slider(v, "Drift", &self.drift, -2, 2, 0.1, "{d:.1}");
        try slider(v, "Size", &self.scalar, 0.4, 3, 0.1, "{d:.1}×");
        try v.spacer(.{});
        if (try v.button("Reset", .{})) self.resetOptions();
        try v.end();
    }

    fn slider(v: *view.View, label: []const u8, value: *f64, minimum: f64, maximum: f64, step: f64, comptime format: []const u8) !void {
        try v.row(.{ .gap = 8, .alignment = .center, .self_align = .stretch });
        try v.text(label, .{ .font = .{ .size = 12 }, .width = 62 });
        _ = try v.slider(value, .{ .minimum = minimum, .maximum = maximum, .step = step }, .{ .name = label, .grow = 1 });
        try v.textf(format, .{value.*}, .{ .font = .{ .size = 12 }, .width = 44, .color = muted });
        try v.end();
    }
};

/// The dashed box that throws the stage's burst from where it is clicked.
const Stage = struct {
    owner: *Confetti = undefined,
    still: bool = false,
    bounds: view.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    fn embed(self: *Stage) view.Embed {
        return .{ .context = self, .measure = measure, .place = place, .paint = paint, .input = input };
    }
    fn measure(_: *anyopaque, _: ui.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 200, .height = 120 }, .preferred = .{ .width = 400, .height = 240 } };
    }
    fn place(ptr: *anyopaque, _: u64, bounds: view.Rect) void {
        const self: *Stage = @ptrCast(@alignCast(ptr));
        self.bounds = bounds;
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, _: u64, b: view.Rect) anyerror!void {
        _ = ptr;
        // A dashed outline: short strokes along each edge.
        const dash: f32 = 6;
        var x = b.x + 10;
        while (x < b.x + b.width - 10) : (x += 2 * dash) {
            const w = @min(dash, b.x + b.width - 10 - x);
            frame.rect(.{ .x = x, .y = b.y, .width = w, .height = 1 }, 0xaab4c2);
            frame.rect(.{ .x = x, .y = b.y + b.height - 1, .width = w, .height = 1 }, 0xaab4c2);
        }
        var y = b.y + 10;
        while (y < b.y + b.height - 10) : (y += 2 * dash) {
            const h = @min(dash, b.y + b.height - 10 - y);
            frame.rect(.{ .x = b.x, .y = y, .width = 1, .height = h }, 0xaab4c2);
            frame.rect(.{ .x = b.x + b.width - 1, .y = y, .width = 1, .height = h }, 0xaab4c2);
        }
        const middle = b.y + b.height / 2;
        centered(frame, b, middle - 26, 24, "Click anywhere here", 0x1f2937, .{ .size = 15, .weight = .bold });
        centered(frame, b, middle, 20, "to throw your burst from the pointer", muted, .{ .size = 12 });
    }
    fn centered(frame: *ui.Frame, b: view.Rect, y: f32, height: f32, label: []const u8, color: u32, font: view.Font) void {
        const width = @min(b.width, (view.Measurer{}).textSize(label, font).width);
        frame.labelFont(.{ .x = b.x + (b.width - width) / 2, .y = y, .width = width + 8, .height = height }, label, color, font);
    }
    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *Stage = @ptrCast(@alignCast(ptr));
        switch (event) {
            .pointer_down => |press| {
                if (!self.still) self.owner.burst(self.owner.custom(self.bounds.x + press.position.x, self.bounds.y + press.position.y));
                return true;
            },
            else => return false,
        }
    }
};

/// The leaf that draws the pieces over the window. It has no size, so the
/// pointer goes through it.
const Layer = struct {
    owner: *Confetti = undefined,
    host: ?*view.Host = null,
    image: ?ui.PixelImage = null,
    queued: bool = false,
    /// Pixels per DIP of the image.
    scale: f32 = 1,

    fn embed(self: *Layer) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint };
    }
    fn measure(_: *anyopaque, _: ui.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 0, .height = 0 }, .preferred = .{ .width = 0, .height = 0 } };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, _: u64, _: view.Rect) anyerror!void {
        const self: *Layer = @ptrCast(@alignCast(ptr));
        const owner = self.owner;
        owner.width = @as(f32, @floatFromInt(frame.size.width)) / frame.size.scale;
        owner.height = @as(f32, @floatFromInt(frame.size.height)) / frame.size.scale;
        const window: view.Rect = .{ .x = 0, .y = 0, .width = owner.width, .height = owner.height };
        if (owner.pieces.items.len > 0) if (self.image) |*image| if (image.view()) |picture| try frame.image(window, picture, .{});
        // Emoji are text, drawn upright over the picture.
        for (owner.pieces.items) |piece| switch (piece.shape) {
            .text => |glyph| {
                if (piece.alpha() < 0.15) continue;
                const size: f32 = @floatCast(12 * piece.scalar);
                frame.labelFont(.{ .x = @as(f32, @floatCast(piece.x)) - size / 2, .y = @as(f32, @floatCast(piece.y)) - size, .width = 2 * size, .height = 2 * size }, glyph, 0, .{ .size = size });
            },
            else => {},
        };
        // The next picture is drawn and uploaded after this paint.
        if ((owner.pieces.items.len > 0 or (self.image != null and self.image.?.view() != null)) and !self.queued) {
            const host = self.host orelse return;
            const app_window = host.context.window orelse return;
            app_window.app.post(.{ .context = self, .call = render }) catch return;
            self.queued = true;
        }
    }

    /// Draws the pieces into the image and shows it; the next paint moves
    /// them on.
    fn render(ptr: *anyopaque) void {
        const self: *Layer = @ptrCast(@alignCast(ptr));
        self.queued = false;
        const host = self.host orelse return;
        const window = host.context.window orelse return;
        const owner = self.owner;
        if (owner.pieces.items.len == 0) {
            if (self.image) |*image| image.release(&host.context);
            return;
        }
        // One pixel per DIP keeps a full window cheap to draw every frame.
        const width: u32 = @intFromFloat(@max(1, @ceil(owner.width)));
        const height: u32 = @intFromFloat(@max(1, @ceil(owner.height)));
        if (self.image) |*image| if (image.width != width or image.height != height) {
            image.release(&host.context);
            image.deinit();
            self.image = null;
        };
        if (self.image == null) self.image = ui.PixelImage.init(owner.allocator, width, height) catch return;
        const image = &self.image.?;
        var canvas: Canvas = .{ .pixels = image.pixels(), .width = width, .height = height };
        @memset(canvas.pixels, 0);
        // canvas-confetti moves a piece before it first draws it.
        for (owner.pieces.items) |*piece| if (piece.tick > 0) canvas.piece(piece);
        image.commit(&host.context) catch |err| std.log.err("confetti: {s}", .{@errorName(err)});
        window.invalidate();
    }
};

/// Premultiplied BGRA pixels the pieces are drawn into, with four samples
/// a pixel.
const Canvas = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    const samples = [_][2]f64{ .{ 0.25, 0.25 }, .{ 0.75, 0.25 }, .{ 0.25, 0.75 }, .{ 0.75, 0.75 } };

    /// Draws a piece as canvas-confetti does.
    fn piece(self: *Canvas, p: *const Piece) void {
        const x1 = p.x + p.random * p.tilt_cos;
        const y1 = p.y + p.random * p.tilt_sin;
        const x2 = p.wobble_x + p.random * p.tilt_cos;
        const y2 = p.wobble_y + p.random * p.tilt_sin;
        const alpha = p.alpha();
        switch (p.shape) {
            .circle => self.ellipse(p.x, p.y, @abs(x2 - x1) * 0.6, @abs(y2 - y1) * 0.6, std.math.pi / 10.0 * p.wobble, p.color, alpha),
            .star => {
                var points: [10][2]f64 = undefined;
                var rotation: f64 = std.math.pi / 2.0 * 3.0;
                const step = std.math.pi / 5.0;
                for (0..5) |i| {
                    points[2 * i] = .{ p.x + @cos(rotation) * 8 * p.scalar, p.y + @sin(rotation) * 8 * p.scalar };
                    rotation += step;
                    points[2 * i + 1] = .{ p.x + @cos(rotation) * 4 * p.scalar, p.y + @sin(rotation) * 4 * p.scalar };
                    rotation += step;
                }
                self.polygon(&points, p.color, alpha);
            },
            .heart => {
                var points: [48][2]f64 = undefined;
                const len = heart(&points, 14 * p.scalar, 13 * p.scalar);
                // Scaled and turned with its wobble, as canvas-confetti
                // draws a path.
                const sx = @abs(x2 - x1) / (10 * p.scalar);
                const sy = @abs(y2 - y1) / (10 * p.scalar);
                const turn = std.math.pi / 10.0 * p.wobble;
                for (points[0..len]) |*point| {
                    const lx = point[0] * sx;
                    const ly = point[1] * sy;
                    point.* = .{ p.x + lx * @cos(turn) - ly * @sin(turn), p.y + lx * @sin(turn) + ly * @cos(turn) };
                }
                self.polygon(points[0..len], p.color, alpha);
            },
            .square => {
                const points = [_][2]f64{ .{ @floor(p.x), @floor(p.y) }, .{ @floor(p.wobble_x), y1 }, .{ x2, y2 }, .{ x1, @floor(p.wobble_y) } };
                self.polygon(&points, p.color, alpha);
            },
            .text => {},
        }
    }

    fn blend(self: *Canvas, x: u32, y: u32, color: u32, alpha: f64) void {
        if (alpha <= 0) return;
        const i = (@as(usize, y) * self.width + x) * 4;
        const a = @min(1, alpha);
        const keep = 1 - a;
        const source = [3]f64{ @floatFromInt(color & 0xff), @floatFromInt((color >> 8) & 0xff), @floatFromInt((color >> 16) & 0xff) };
        for (0..3) |c| self.pixels[i + c] = @intFromFloat(@min(255, source[c] * a + @as(f64, @floatFromInt(self.pixels[i + c])) * keep + 0.5));
        self.pixels[i + 3] = @intFromFloat(@min(255, 255 * a + @as(f64, @floatFromInt(self.pixels[i + 3])) * keep + 0.5));
    }

    /// The pixels a box from (left, top) to (right, bottom) touches.
    fn span(self: *const Canvas, left: f64, top: f64, right: f64, bottom: f64) ?[4]u32 {
        if (!(right > 0 and bottom > 0 and left < @as(f64, @floatFromInt(self.width)) and top < @as(f64, @floatFromInt(self.height)))) return null;
        return .{
            @intFromFloat(@max(0, @floor(left))),
            @intFromFloat(@max(0, @floor(top))),
            @intFromFloat(@min(@as(f64, @floatFromInt(self.width)), @ceil(right))),
            @intFromFloat(@min(@as(f64, @floatFromInt(self.height)), @ceil(bottom))),
        };
    }

    /// Fills a polygon by the nonzero rule.
    fn polygon(self: *Canvas, points: []const [2]f64, color: u32, alpha: f64) void {
        var left = points[0][0];
        var right = left;
        var top = points[0][1];
        var bottom = top;
        for (points) |point| {
            left = @min(left, point[0]);
            right = @max(right, point[0]);
            top = @min(top, point[1]);
            bottom = @max(bottom, point[1]);
        }
        const box = self.span(left, top, right, bottom) orelse return;
        var y = box[1];
        while (y < box[3]) : (y += 1) {
            var x = box[0];
            while (x < box[2]) : (x += 1) {
                var covered: f64 = 0;
                for (samples) |offset| {
                    if (inside(points, @as(f64, @floatFromInt(x)) + offset[0], @as(f64, @floatFromInt(y)) + offset[1])) covered += 0.25;
                }
                self.blend(x, y, color, alpha * covered);
            }
        }
    }

    fn inside(points: []const [2]f64, x: f64, y: f64) bool {
        var winding: i32 = 0;
        for (points, 0..) |a, i| {
            const b = points[(i + 1) % points.len];
            if (a[1] <= y) {
                if (b[1] > y and (b[0] - a[0]) * (y - a[1]) - (x - a[0]) * (b[1] - a[1]) > 0) winding += 1;
            } else if (b[1] <= y and (b[0] - a[0]) * (y - a[1]) - (x - a[0]) * (b[1] - a[1]) < 0) winding -= 1;
        }
        return winding != 0;
    }

    /// Fills an ellipse with radii (rx, ry) turned by `rotation`.
    fn ellipse(self: *Canvas, cx: f64, cy: f64, rx: f64, ry: f64, rotation: f64, color: u32, alpha: f64) void {
        if (rx < 0.05 or ry < 0.05) return;
        const reach = @max(rx, ry);
        const box = self.span(cx - reach, cy - reach, cx + reach, cy + reach) orelse return;
        const c = @cos(rotation);
        const s = @sin(rotation);
        var y = box[1];
        while (y < box[3]) : (y += 1) {
            var x = box[0];
            while (x < box[2]) : (x += 1) {
                var covered: f64 = 0;
                for (samples) |offset| {
                    const dx = @as(f64, @floatFromInt(x)) + offset[0] - cx;
                    const dy = @as(f64, @floatFromInt(y)) + offset[1] - cy;
                    const u = (dx * c + dy * s) / rx;
                    const v = (-dx * s + dy * c) / ry;
                    if (u * u + v * v <= 1) covered += 0.25;
                }
                self.blend(x, y, color, alpha * covered);
            }
        }
    }
};

/// A heart of `w` by `h` around (0, 0), its curves flattened into `out`.
fn heart(out: *[48][2]f64, w: f64, h: f64) usize {
    const x = -w / 2;
    const y = -h / 2;
    const curves = [_][4][2]f64{
        .{ .{ x + w / 2, y + h }, .{ x - w * 0.15, y + h * 0.55 }, .{ x + w * 0.05, y - h * 0.1 }, .{ x + w / 2, y + h * 0.22 } },
        .{ .{ x + w / 2, y + h * 0.22 }, .{ x + w * 0.95, y - h * 0.1 }, .{ x + w * 1.15, y + h * 0.55 }, .{ x + w / 2, y + h } },
    };
    var len: usize = 0;
    for (curves) |curve| {
        for (0..24) |i| {
            const t = @as(f64, @floatFromInt(i)) / 24;
            const u = 1 - t;
            var point: [2]f64 = undefined;
            for (0..2) |axis| point[axis] = u * u * u * curve[0][axis] + 3 * u * u * t * curve[1][axis] + 3 * u * t * t * curve[2][axis] + t * t * t * curve[3][axis];
            out[len] = point;
            len += 1;
        }
    }
    return len;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var confetti: Confetti = .init(allocator);
    defer confetti.deinit();
    var storage: view.Storage(256, 8 * 1024) = .{};
    var host = view.Host.init(&confetti, Confetti.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(24) } });
    confetti.layer.host = &host;
    var timer = view_timer.Timer.init(&host);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Confetti", .width = window_width, .height = window_height, .min_width = 760, .min_height = 560 });
    try host.attach(window);
    try timer.attach(app, allocator);
    window.show();
    try app.run();
    try timer.close();
    confetti.layer.host = null;
}

fn harness(confetti: *Confetti, storage: anytype) view.Harness {
    return view.Harness.init(confetti, Confetti.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = window_width, .height = window_height } });
}

test "a demo throws its pieces, which go once they faded; the stage throws from the pointer" {
    var confetti: Confetti = .init(std.testing.allocator);
    defer confetti.deinit();
    var storage: view.Storage(256, 8 * 1024) = .{};
    var h = harness(&confetti, &storage);
    try h.render();
    try h.click(.{ .text = "Basic Cannon" });
    try std.testing.expectEqual(@as(usize, 100), confetti.pieces.items.len);
    try h.render();
    _ = try h.find(.{ .text = "100 in the air" });
    // The burst starts below the middle and heads up.
    const start = confetti.pieces.items[0].y;
    try h.advance(10 * tick);
    try std.testing.expect(confetti.pieces.items[0].y < start);
    try h.advance(200 * tick);
    try std.testing.expectEqual(@as(usize, 0), confetti.pieces.items.len);

    const stage = try h.find(.{ .name = "Stage" });
    const at: [2]f32 = .{ stage.bounds.x + 40, stage.bounds.y + 30 };
    try h.clickAt(at[0], at[1]);
    try std.testing.expectEqual(@as(usize, 150), confetti.pieces.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, at[0]), confetti.pieces.items[0].x, 1);
    try std.testing.expectApproxEqAbs(@as(f64, at[1]), confetti.pieces.items[0].y, 1);
}

test "pressing a demo again and again lets the oldest pieces go first" {
    var confetti: Confetti = .init(std.testing.allocator);
    defer confetti.deinit();
    var storage: view.Storage(256, 8 * 1024) = .{};
    var h = harness(&confetti, &storage);
    try h.render();
    for (0..8) |_| try h.click(.{ .text = "Realistic Look" });
    try std.testing.expectEqual(@as(usize, max_pieces), confetti.pieces.items.len);
    // The last burst of the last press is last.
    try std.testing.expectEqual(@as(f64, 1.2), confetti.pieces.items[max_pieces - 21].scalar);
}

test "fireworks fire two bursts now and two more every 250 ms for 5 s" {
    var confetti: Confetti = .init(std.testing.allocator);
    defer confetti.deinit();
    var storage: view.Storage(256, 8 * 1024) = .{};
    var h = harness(&confetti, &storage);
    try h.render();
    try h.click(.{ .text = "Fireworks" });
    try std.testing.expectEqual(@as(usize, 100), confetti.pieces.items.len);
    try std.testing.expectEqual(@as(usize, 1), confetti.emitters.items.len);
    try h.advance(250 * std.time.ns_per_ms);
    try std.testing.expect(confetti.pieces.items.len > 100);
    try h.advance(5 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 0), confetti.emitters.items.len);
}

test "nothing flies while the desktop asks for less motion" {
    var confetti: Confetti = .init(std.testing.allocator);
    defer confetti.deinit();
    var storage: view.Storage(256, 8 * 1024) = .{};
    var h = harness(&confetti, &storage);
    h.view.preferences.reduce_motion = true;
    try h.render();
    try h.click(.{ .text = "Realistic Look" });
    try std.testing.expectEqual(@as(usize, 0), confetti.pieces.items.len);
    _ = try h.find(.{ .text = "Confetti rests while the desktop asks for less motion." });
}

test "pieces draw inside the canvas and fade" {
    var pixels: [32 * 32 * 4]u8 = @splat(0);
    var canvas: Canvas = .{ .pixels = &pixels, .width = 32, .height = 32 };
    var piece: Piece = .{ .x = 16, .y = 16, .wobble = 0, .wobble_speed = 0.1, .velocity = 0, .angle = 0, .tilt_angle = 0, .color = 0xff0000, .shape = .star, .total_ticks = 10, .decay = 0.9, .drift = 0, .random = 2, .gravity = 0, .scalar = 1, .flat = true };
    var prng: std.Random.DefaultPrng = .init(1);
    _ = piece.update(prng.random());
    canvas.piece(&piece);
    // The star's middle is red, premultiplied, at nine tenths.
    const middle = (16 * 32 + 16) * 4;
    try std.testing.expectEqual(@as(u8, 0), pixels[middle]);
    try std.testing.expect(pixels[middle + 2] > 200 and pixels[middle + 3] > 200);
    // Pieces outside draw nothing.
    @memset(&pixels, 0);
    piece.x = -100;
    canvas.piece(&piece);
    for (pixels) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    var points: [48][2]f64 = undefined;
    try std.testing.expectEqual(@as(usize, 48), heart(&points, 14, 13));
}
