//! The "galaxy brain effort slider" demo in native UI: a card whose slider
//! steps from Low to Max with a brain for a thumb, and past Max into
//! Galaxy, where the brain bursts, the card shakes, the track fills with
//! twinkling pixels and dotted rays stream out of the brain.
//!
//! Drag the brain, click the track or press the arrow keys, Home and End.
//! The card is drawn on the CPU into a `ui.PixelImage`, its brain from the
//! outline of an icon through `ziggurat_vector`; its words are labels over
//! it.
//!
//! Run it with `zig build run-effort-slider`.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");
const vector = @import("ziggurat_vector");

// The window shows the demo's frame: the card a little above the middle.
const window_width = 472;
const window_height = 258;
const card_width: f32 = 220;
const card_height: f32 = 129.5;
const card_y: f32 = 62;

// The card's parts, in DIPs from its top left corner.
const card_radius: f32 = 8;
const title_size: f32 = 13.25;
const title_baseline: f32 = 26;
const effort_x: f32 = 12.2;
const value_x: f32 = 54.6;
const help_x: f32 = 200;
const help_y: f32 = 20.9;
const help_radius: f32 = 6;
const label_size: f32 = 12;
const label_baseline: f32 = 60.4;
const faster_x: f32 = 12.1;
const smarter_right: f32 = 208.1;
const track_x: f32 = 12;
const track_y: f32 = 75;
const track_width: f32 = 196;
const track_height: f32 = 20;
const track_radius: f32 = 5;
// The ticks of the levels; the second, the one recommended, is a bar.
const tick_x: f32 = 23;
const tick_gap: f32 = 34.8;
const tick_size: f32 = 3.0;
const bar_height: f32 = 10;
const recommended_x: f32 = 24.6;
const recommended_baseline: f32 = 114;
// The thumb's center goes 36 DIPs a level from stop_x.
const stop_x: f32 = 20;
const stop_gap: f32 = 36;
const brain_size: f32 = 24;
const galaxy_brain: f32 = 32.0;
const galaxy_brain_y: f32 = 85.1;
const brain_y: f32 = 85.5;
// The fill ends under the brain, short of its center.
const fill_inset: f32 = 10;

const levels = [_][]const u8{ "Low", "Medium", "High", "Extra", "Max", "Galaxy" };
const galaxy = 5;

const page_color: u32 = 0x101010;
const card_color: u32 = 0x171717;
const border_color: u32 = 0x262626;
const track_color: u32 = 0x262626;
const title_color: u32 = 0x767676;
const value_color: u32 = 0xe5e5e5;
const label_color: u32 = 0x6f6f6f;
const recommend_color: u32 = 0x777777;
const dot_color: u32 = 0x525252;
const bar_color: u32 = 0x5f5f5f;
const brain_fill: u32 = 0xfd92ba;
const brain_stroke: u32 = 0x611836;
const fill_from: u32 = 0x9f5a7a;
const fill_to: u32 = 0x6958a7;
const fill_alpha: f32 = 0.071;
const galaxy_stroke: u32 = 0x22137c;
const galaxy_from: u32 = 0x8b91fd;
const galaxy_to: u32 = 0xb781f3;
const galaxy_track: u32 = 0x0f0a21;
const galaxy_track2: u32 = 0x3b2a78;
const galaxy_label: u32 = 0x8fd0f6;
const pixel_colors = [_]u32{ 0xf472b6, 0xc084fc, 0xa78bfa, 0x818cf8, 0x67e8f9, 0x7dd3fc, 0xf5f3ff, 0xe9d5ff };
const burst_colors = [_]u32{ 0x5b3cf0, 0x67e8f9, 0xffffff, 0xf472b6, 0xa78bfa };
const ray_colors = [_]u32{ 0x5fb4bd, 0x9a9aac, 0xb3a8f0 };

const ms = std.time.ns_per_ms;
// The thumb eases to a level as CSS's cubic-bezier(0.19, 1, 0.22, 1) does.
const move_time = 500 * ms;
const move_ease: Bezier = .{ .x1 = 0.19, .y1 = 1, .x2 = 0.22, .y2 = 1 };
// The old label goes up and fades out; the new one rises and fades in.
const in_stagger = 14500 * std.time.ns_per_us;
const in_time = 320 * ms;
const out_delay = 25 * ms;
const out_time = 355 * ms;
const in_y: f32 = 3.0;
const out_y: f32 = 3.4;
const label_ease: Bezier = .{ .x1 = 0.25, .y1 = 0.1, .x2 = 0.25, .y2 = 1 };
const back_out: Bezier = .{ .x1 = 0.34, .y1 = 1.56, .x2 = 0.64, .y2 = 1 };
const galaxy_in = 160 * ms;
const galaxy_out = 250 * ms;
const burst_time = 650 * ms;
const flash_time = 550 * ms;
const track_in = 50 * ms;
const pixel_pitch: f32 = 4;

/// How far the card jumps in the frames after Galaxy starts, a 60th of a
/// second apart.
const shake = [_][2]f32{
    .{ 0.75, 1 },      .{ -0.78, 0.3 },   .{ 0.9, -1.03 }, .{ 0.4, 0.37 },   .{ 0.25, 0 },    .{ 0.15, -0.2 },
    .{ 0.15, 0.32 },   .{ -0.5, -0.22 },  .{ -0.22, 0 },   .{ 0.15, -0.25 }, .{ -0.3, 0.35 }, .{ -0.22, -0.15 },
    .{ -0.15, -0.08 }, .{ -0.05, -0.02 },
};

/// The brain of Lucide 0.4, whose hemispheres close so that they fill: 24
/// units square, stroked 2 units wide with round caps and joins.
const brain_fill_path = "M12 5a3 3 0 1 0-5.997.125 4 4 0 0 0-2.526 5.77 4 4 0 0 0 .556 6.588A4 4 0 1 0 12 18Z" ++
    "M12 5a3 3 0 1 1 5.997.125 4 4 0 0 1 2.526 5.77 4 4 0 0 1-.556 6.588A4 4 0 1 1 12 18Z";
const brain_path = brain_fill_path ++ "M15 13a4.5 4.5 0 0 1-3-4 4.5 4.5 0 0 1-3 4M17.599 6.5a3 3 0 0 0 .399-1.375M6.003 5.125A3 3 0 0 0 6.401 6.5" ++
    "M3.477 10.896a4 4 0 0 1 .585-.396M19.938 10.5a4 4 0 0 1 .585.396M6 18a4 4 0 0 1-1.967-.516M19.967 17.484A4 4 0 0 1 18 18";

/// CSS's cubic-bezier timing function.
const Bezier = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,

    fn curve(a: f64, b: f64, s: f64) f64 {
        return 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s;
    }
    fn at(self: Bezier, t: f64) f64 {
        if (t <= 0 or t >= 1) return std.math.clamp(t, 0, 1);
        // Newton's method for the s at which the curve is at t, then
        // bisection where it stalls.
        var s = t;
        for (0..8) |_| {
            const x = curve(self.x1, self.x2, s) - t;
            const d = 3 * self.x1 * (1 - s) * (1 - s) + 6 * (self.x2 - self.x1) * s * (1 - s) + 3 * (1 - self.x2) * s * s;
            if (@abs(x) < 1e-7 or @abs(d) < 1e-6) break;
            s -= x / d;
        }
        var lo: f64 = 0;
        var hi: f64 = 1;
        for (0..40) |_| {
            const x = curve(self.x1, self.x2, s);
            if (@abs(x - t) < 1e-7) break;
            if (x < t) lo = s else hi = s;
            s = (lo + hi) / 2;
        }
        return curve(self.y1, self.y2, s);
    }
};

/// A number from 0 to 1 that only depends on its arguments.
fn hash(a: usize, b: usize, c: usize) f32 {
    var h: u32 = @as(u32, @truncate(a)) *% 0x9e3779b1 ^ @as(u32, @truncate(b)) *% 0x85ebca77 ^ @as(u32, @truncate(c)) *% 0xc2b2ae3d;
    h ^= h >> 15;
    h *%= 0x2c1b3c6d;
    h ^= h >> 12;
    h *%= 0x297a2d39;
    h ^= h >> 15;
    return @as(f32, @floatFromInt(h & 0xffffff)) / 0xffffff;
}

/// How lit a pixel seeded by a and b is at t seconds: it blinks on and off
/// at a pace of its own.
fn twinkle(a: usize, b: usize, t: f64) f32 {
    const period = 0.7 + 1.1 * @as(f64, hash(a, b, 1));
    const phase: f64 = hash(a, b, 2);
    const k = @mod(t / period + phase, 1);
    const on = 0.35 + 0.4 * @as(f64, hash(a, b, 3));
    if (k > on) return 0;
    return @floatCast(@sin(k / on * std.math.pi));
}

fn shimmer(a: usize, b: usize, t: f64) f32 {
    const period = 0.5 + @as(f64, hash(a, b, 1));
    return @floatCast(0.5 + 0.5 * @sin(2 * std.math.pi * (t / period + @as(f64, hash(a, b, 2)))));
}

fn smoothstep(lo: f32, hi: f32, x: f32) f32 {
    const k = std.math.clamp((x - lo) / (hi - lo), 0, 1);
    return k * k * (3 - 2 * k);
}

fn mix(a: u32, b: u32, k: f32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const x: f32 = @floatFromInt((a >> shift) & 0xff);
        const y: f32 = @floatFromInt((b >> shift) & 0xff);
        out |= @as(u32, @intFromFloat(@round(x + (y - x) * std.math.clamp(k, 0, 1)))) << shift;
    }
    return out;
}

const Slider = struct {
    /// The level the thumb goes to.
    level: usize = 0,
    /// Where the thumb was when it set off, and when.
    from: f64 = 0,
    moved_at: ?u64 = null,
    /// The level the label showed before, and when it changed.
    prev: usize = 0,
    changed_at: ?u64 = null,
    /// When the slider went Galaxy, and left it.
    galaxy_at: ?u64 = null,
    galaxy_left: ?u64 = null,
    /// While the pointer holds the thumb, it stays under the pointer, at
    /// `held` levels; let go, it eases to the nearest level.
    holding: bool = false,
    held: f64 = 0,
    /// The time of the last pass, for input between passes.
    now: u64 = 0,
    /// Where the card's top left corner is, without the shake.
    origin: [2]f32 = .{ 126, card_y },
    picture: Picture = .{},

    /// Where the thumb is at t, in levels, and whether it is still moving.
    fn thumb(self: *const Slider, t: u64) struct { f64, bool } {
        if (self.holding) return .{ self.held, false };
        const at = self.moved_at orelse return .{ @floatFromInt(self.level), false };
        const k = @as(f64, @floatFromInt(t -| at)) / move_time;
        if (k >= 1) return .{ @floatFromInt(self.level), false };
        return .{ self.from + (@as(f64, @floatFromInt(self.level)) - self.from) * move_ease.at(k), true };
    }

    fn setLevel(self: *Slider, level: usize, t: u64) void {
        if (level == self.level) return;
        self.from = self.thumb(t)[0];
        self.prev = self.level;
        self.changed_at = t;
        if (level == galaxy) {
            self.galaxy_at = t;
            self.galaxy_left = null;
        } else if (self.level == galaxy) self.galaxy_left = t;
        self.level = level;
        self.moved_at = t;
    }

    fn hold(self: *Slider, position: f64, t: u64) void {
        self.holding = true;
        self.held = std.math.clamp(position, 0, galaxy);
        self.setLevel(@intFromFloat(@round(self.held)), t);
    }

    fn release(self: *Slider, t: u64) void {
        if (!self.holding) return;
        self.holding = false;
        self.from = self.held;
        self.moved_at = t;
    }

    /// How far into Galaxy the slider is at t: 0 out of it, 1 in it.
    fn galaxyLevel(self: *const Slider, t: u64) f32 {
        const at = self.galaxy_at orelse return 0;
        if (self.galaxy_left) |left| return @max(0, 1 - @as(f32, @floatFromInt(t -| left)) / galaxy_out);
        return @min(1, @as(f32, @floatFromInt(t -| at)) / galaxy_in);
    }

    fn shakeAt(self: *const Slider, t: u64) [2]f32 {
        const at = self.galaxy_at orelse return .{ 0, 0 };
        if (self.galaxy_left != null) return .{ 0, 0 };
        const f = @as(f64, @floatFromInt(t -| at)) / std.time.ns_per_s * 60;
        const i: usize = @intFromFloat(f);
        if (i >= shake.len) return .{ 0, 0 };
        const a = shake[i];
        const b = if (i + 1 < shake.len) shake[i + 1] else [2]f32{ 0, 0 };
        const k: f32 = @floatCast(f - @as(f64, @floatFromInt(i)));
        return .{ a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k };
    }

    /// Whether anything still moves at t.
    fn animating(self: *const Slider, t: u64) bool {
        if (self.thumb(t)[1] or self.galaxyLevel(t) > 0) return true;
        const changed = self.changed_at orelse return false;
        return t -| changed < @max(out_delay + out_time, in_stagger * (levels[self.level].len - 1) + in_time);
    }

    fn build(self: *Slider, v: *view.View) anyerror!void {
        self.now = v.time();
        try v.embed(self.picture.embed(self), .{ .grow = 1, .self_align = .stretch, .key = 1, .name = "Effort" });
        if (self.animating(self.now)) v.wakeAt(self.now + std.time.ns_per_s / 60);
    }

    /// The level the pointer is over, in levels along the track.
    fn levelAt(x: f32) f64 {
        return (x - stop_x) / stop_gap;
    }

    fn input(self: *Slider, event: view.EmbedInput) bool {
        const t = self.now;
        switch (event) {
            .pointer_down => |press| {
                const x = press.position.x - self.origin[0];
                const y = press.position.y - self.origin[1];
                if (x < track_x - 4 or x > track_x + track_width + 4 or y < track_y - 10 or y > track_y + track_height + 10) return false;
                self.hold(levelAt(x), t);
                return true;
            },
            .pointer_drag => |drag| {
                if (!self.holding) return false;
                self.hold(levelAt(drag.position.x - self.origin[0]), t);
                return true;
            },
            .pointer_up, .pointer_cancel => {
                self.release(t);
                return true;
            },
            .key => |key| {
                const level: usize = switch (key.key) {
                    .right, .up => @min(galaxy, self.level + 1),
                    .left, .down => self.level -| 1,
                    .home => 0,
                    .end => galaxy,
                    else => return false,
                };
                self.release(t);
                self.setLevel(level, t);
                return true;
            },
            else => return false,
        }
    }
};

/// The leaf that shows the card: the picture drawn on the CPU, and the
/// words over it.
const Picture = struct {
    slider: *Slider = undefined,
    host: ?*view.Host = null,
    allocator: ?std.mem.Allocator = null,
    image: ?ui.PixelImage = null,
    brain_fill: ?*vector.Path = null,
    brain_outline: ?*vector.Path = null,
    queued: bool = false,
    /// The time the picture shows, so that it is drawn once a frame.
    drawn: ?u64 = null,
    size: [2]f32 = .{ window_width, window_height },
    /// The leaf's top left corner in the window.
    at: [2]f32 = .{ 0, 0 },
    scale: f32 = 1,

    fn embed(self: *Picture, slider: *Slider) view.Embed {
        self.slider = slider;
        return .{ .context = self, .measure = measure, .place = place, .paint = paint, .input = input, .focusable = true };
    }
    fn measure(_: *anyopaque, _: ui.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = card_width, .height = card_height }, .preferred = .{ .width = window_width, .height = window_height } };
    }
    fn place(ptr: *anyopaque, _: u64, bounds: view.Rect) void {
        const self: *Picture = @ptrCast(@alignCast(ptr));
        self.size = .{ bounds.width, bounds.height };
        self.at = .{ bounds.x, bounds.y };
        // Centered across, on whole DIPs so that the card's edges are crisp.
        self.slider.origin = .{ bounds.x + @round((bounds.width - card_width) / 2), bounds.y + @round(card_y + (bounds.height - window_height) / 2) };
    }
    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *Picture = @ptrCast(@alignCast(ptr));
        // Pointer positions arrive local to the leaf.
        var moved = event;
        switch (moved) {
            .pointer_down => |*press| press.position = .{ .x = press.position.x + self.at[0], .y = press.position.y + self.at[1] },
            .pointer_drag => |*drag| drag.position = .{ .x = drag.position.x + self.at[0], .y = drag.position.y + self.at[1] },
            else => {},
        }
        return self.slider.input(moved);
    }

    fn paint(ptr: *anyopaque, frame: *ui.Frame, _: u64, bounds: view.Rect) anyerror!void {
        const self: *Picture = @ptrCast(@alignCast(ptr));
        const s = self.slider;
        const t = s.now;
        frame.rect(bounds, page_color);
        if (self.image) |*image| if (image.view()) |picture| try frame.image(bounds, picture, .{});
        self.scale = frame.size.scale;
        const offset = s.shakeAt(t);
        const ox = s.origin[0] + offset[0];
        const oy = s.origin[1] + offset[1];
        word(frame, "Effort", ox + effort_x, oy + title_baseline, title_color, title_size, .medium);
        word(frame, "Faster", ox + faster_x, oy + label_baseline, label_color, label_size, .regular);
        const smarter = (view.Measurer{}).textSize("Smarter", .{ .size = label_size }).width;
        word(frame, "Smarter", ox + smarter_right - smarter, oy + label_baseline, label_color, label_size, .regular);
        word(frame, "Recommended", ox + recommended_x, oy + recommended_baseline, recommend_color, label_size, .regular);
        word(frame, "?", ox + help_x - 2.4, oy + help_y + 3.2, title_color, 8.8, .semibold);
        self.label(frame, ox + value_x, oy + title_baseline, t);
        // The next picture is drawn after this paint.
        if ((self.drawn == null or self.drawn.? != t) and !self.queued) {
            const host = self.host orelse return;
            const window = host.context.window orelse return;
            window.app.post(.{ .context = self, .call = render }) catch return;
            self.queued = true;
        }
    }

    /// The level's label, and the last one while it goes: the old one
    /// rises and fades, the new one comes up into place.
    fn label(self: *Picture, frame: *ui.Frame, x: f32, y: f32, t: u64) void {
        const s = self.slider;
        const current = levels[s.level];
        const changed = s.changed_at orelse return word(frame, current, x, y, colorOf(s.level), title_size, .medium);
        const since = t -| changed;
        const out: f32 = @floatCast(label_ease.at(@as(f64, @floatFromInt(since -| out_delay)) / out_time));
        if (out < 1) word(frame, levels[s.prev], x, y - out_y * out, mix(colorOf(s.prev), card_color, out), title_size, .medium);
        const all = in_time + in_stagger * (current.len - 1);
        const k: f32 = @floatCast(label_ease.at(@as(f64, @floatFromInt(since)) / @as(f64, @floatFromInt(all))));
        if (k > 0) word(frame, current, x, y + in_y * (1 - k), mix(card_color, colorOf(s.level), k), title_size, .medium);
    }

    fn colorOf(level: usize) u32 {
        return if (level == galaxy) galaxy_label else value_color;
    }

    /// Text from x with its baseline at y.
    fn word(frame: *ui.Frame, text: []const u8, x: f32, y: f32, color: u32, size: f32, weight: view.Font.Weight) void {
        const font: view.Font = .{ .size = size, .weight = weight };
        const width = (view.Measurer{}).textSize(text, font).width;
        // Labels center their line in their box: a box a line tall puts the
        // baseline about four fifths of the size down.
        const height = size * 1.4;
        // The width is an estimate: room to spare keeps the words whole.
        frame.labelFont(.{ .x = x, .y = y - size * 0.8 - (height - size) / 2, .width = width * 1.4 + 8, .height = height }, text, color, font);
    }

    fn render(ptr: *anyopaque) void {
        const self: *Picture = @ptrCast(@alignCast(ptr));
        self.queued = false;
        const host = self.host orelse return;
        const window = host.context.window orelse return;
        const allocator = self.allocator orelse return;
        const t = self.slider.now;
        const width: u32 = @intFromFloat(@max(1, @round(self.size[0] * self.scale)));
        const height: u32 = @intFromFloat(@max(1, @round(self.size[1] * self.scale)));
        if (self.image) |*image| if (image.width != width or image.height != height) {
            image.release(&host.context);
            image.deinit();
            self.image = null;
        };
        if (self.image == null) self.image = ui.PixelImage.init(allocator, width, height) catch return;
        const image = &self.image.?;
        var canvas: Canvas = .{ .pixels = image.pixels(), .width = width, .height = height, .scale = self.scale };
        canvas.clear(page_color);
        self.drawCard(&canvas, allocator, t) catch |err| std.log.err("effort: {s}", .{@errorName(err)});
        image.commit(&host.context) catch |err| return std.log.err("effort: {s}", .{@errorName(err)});
        self.drawn = t;
        window.invalidate();
    }

    fn drawCard(self: *Picture, c: *Canvas, allocator: std.mem.Allocator, t: u64) !void {
        const s = self.slider;
        const position: f32 = @floatCast(s.thumb(t)[0]);
        const g = s.galaxyLevel(t);
        const secs = if (s.galaxy_at) |at| @as(f64, @floatFromInt(t -| at)) / std.time.ns_per_s else 0;
        const offset = s.shakeAt(t);
        const ox = s.origin[0] + offset[0];
        const oy = s.origin[1] + offset[1];

        // The card on Tailwind's shadow-lg, with a 1 DIP border.
        c.shadow(ox, oy + 10, card_width, card_height, card_radius, 15, -3, 0.1);
        c.shadow(ox, oy + 4, card_width, card_height, card_radius, 6, -4, 0.1);
        c.roundRect(ox, oy, card_width, card_height, card_radius, .{ .solid = border_color }, 1);
        c.roundRect(ox + 1, oy + 1, card_width - 2, card_height - 2, card_radius - 1, .{ .solid = card_color }, 1);
        c.ring(ox + help_x, oy + help_y, help_radius - 0.5, 1, title_color, 1);

        // The track, and the fill up to the thumb: a gradient across the
        // whole track, more opaque toward the thumb.
        c.roundRect(ox + track_x, oy + track_y, track_width, track_height, track_radius, .{ .solid = track_color }, 1);
        const thumb_x = stop_x + stop_gap * position;
        const end = thumb_x - fill_inset;
        if (end > track_x) {
            const w = end - track_x;
            const radius = @min(track_radius, w / 2);
            c.roundRect(ox + track_x, oy + track_y, w, track_height, radius, .{ .across = .{ .x = ox + track_x, .width = track_width, .from = fill_from, .to = fill_to, .from_alpha = 1, .to_alpha = 1 } }, 1);
            c.roundRect(ox + track_x, oy + track_y, w, track_height, radius, .{ .across = .{ .x = ox + track_x, .width = w, .from = track_color, .to = track_color, .from_alpha = 1 - fill_alpha, .to_alpha = 0 } }, 1);
        }
        const gt = if (s.galaxy_left == null and s.galaxy_at != null) @min(1, @as(f32, @floatFromInt(t -| s.galaxy_at.?)) / track_in) else g;
        galaxyTrack(c, ox, oy, thumb_x, gt, secs);

        // The ticks.
        for (0..levels.len) |i| {
            const x = ox + tick_x + tick_gap * @as(f32, @floatFromInt(i));
            if (i == 1) {
                c.roundRect(x - tick_size / 2, oy + track_y + track_height / 2 - bar_height / 2, tick_size, bar_height, tick_size / 2, .{ .solid = mix(bar_color, 0xc8c4dc, g) }, 1);
            } else c.roundRect(x - tick_size / 2, oy + track_y + track_height / 2 - tick_size / 2, tick_size, tick_size, tick_size / 2, .{ .solid = dot_color }, 1 - g);
        }

        // The brain, and in Galaxy its rays and glow behind it, the burst
        // and the flash over it. In Galaxy it grows by a third, a little
        // past it at first.
        const grow: f32 = @floatCast(1 + (galaxy_brain / brain_size - 1) * back_out.at(g));
        const bx = ox + thumb_x;
        const by = oy + brain_y + (galaxy_brain_y - brain_y) * g;
        if (g > 0) {
            rays(c, bx, by, g, secs);
            c.glow(bx, by, 34, 0x7c74ff, 0.4 * g);
        }
        const size = brain_size * grow;
        if (g < 1) try self.brain(c, allocator, bx, by, size, .{ .solid = brain_fill }, brain_stroke, 1);
        if (g > 0) try self.brain(c, allocator, bx, by, size, .{ .diagonal = .{ .x = bx - size / 2, .y = by - size / 2, .size = size, .from = galaxy_from, .to = galaxy_to } }, galaxy_stroke, g);
        if (g > 0) sparkles(c, bx, by, g, secs);
        if (s.galaxy_left == null) if (s.galaxy_at) |at| {
            const since = t -| at;
            burst(c, bx, by, @as(f32, @floatFromInt(since)) / burst_time);
            const k = @as(f32, @floatFromInt(since)) / flash_time;
            if (k < 1) c.glow(bx, by, 44, 0xf4f2ff, 0.6 * std.math.pow(f32, 1 - k, 1.6));
        };
    }

    /// The brain filled with `fill` and outlined in `stroke`, `alpha`
    /// opaque, `size` DIPs square around (cx, cy).
    fn brain(self: *Picture, c: *Canvas, allocator: std.mem.Allocator, cx: f32, cy: f32, size: f32, fill: Paint, stroke: u32, alpha: f32) !void {
        if (self.brain_fill == null) self.brain_fill = try vector.Path.parseData(allocator, brain_fill_path, .{});
        if (self.brain_outline == null) self.brain_outline = try vector.Path.parseData(allocator, brain_path, .{});
        const unit: f64 = size / 24;
        const transform: vector.Transform = .{ .xx = unit, .yy = unit, .x0 = cx - 12 * unit, .y0 = cy - 12 * unit };
        const viewport: ui.drawing.Rect = .{ .x = cx - size, .y = cy - size, .width = 2 * size, .height = 2 * size };
        const options: vector.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .viewport = viewport, .scale = c.scale, .transform = transform };
        const filled = try self.brain_fill.?.prepare(allocator, options);
        defer filled.close() catch {};
        c.coverage(filled.coverage, fill, alpha);
        var outline = options;
        outline.style = .{ .stroke = .{ .width = 2, .cap = .round, .join = .round } };
        const stroked = try self.brain_outline.?.prepare(allocator, outline);
        defer stroked.close() catch {};
        c.coverage(stroked.coverage, .{ .solid = stroke }, alpha);
    }

    fn deinit(self: *Picture) void {
        if (self.brain_fill) |path| path.close() catch {};
        if (self.brain_outline) |path| path.close() catch {};
        if (self.image) |*image| image.deinit();
    }
};

/// The track's fill in Galaxy, up to the thumb: deep violet, with a grid of
/// pixels shimmering, dim far from the brain and bright next to it.
fn galaxyTrack(c: *Canvas, ox: f32, oy: f32, thumb_x: f32, g: f32, secs: f64) void {
    const end = thumb_x - fill_inset;
    if (end <= track_x or g <= 0) return;
    c.roundRect(ox + track_x, oy + track_y, end - track_x, track_height, track_radius, .{ .across = .{ .x = ox + track_x, .width = end - track_x, .from = galaxy_track, .to = galaxy_track2, .from_alpha = 1, .to_alpha = 1 } }, g);
    const columns: usize = @intFromFloat(@max(0, (thumb_x - track_x - 2) / pixel_pitch));
    for (0..columns) |col| {
        const x = track_x + 0.5 + @as(f32, @floatFromInt(col)) * pixel_pitch;
        const u = (x - track_x) / (thumb_x - track_x);
        for (0..5) |row| {
            if (hash(col, row, 0) > 0.45 + u) continue;
            const bright = 0.12 + 0.88 * smoothstep(0.3, 0.95, u);
            const a = bright * (0.5 + 0.5 * shimmer(col, row, secs)) * g;
            if (a < 0.03) continue;
            const color = pixel_colors[@as(usize, @intFromFloat(hash(col, row, 4) * pixel_colors.len)) % pixel_colors.len];
            c.roundRect(ox + x, oy + track_y + 0.5 + @as(f32, @floatFromInt(row)) * pixel_pitch, 3, 3, 0.8, .{ .solid = color }, a);
        }
    }
}

/// The dotted rays streaming out of the brain.
fn rays(c: *Canvas, cx: f32, cy: f32, g: f32, secs: f64) void {
    const count = 16;
    const from: f32 = 19;
    for (0..count) |i| {
        const angle = (@as(f64, @floatFromInt(i)) + 0.4 * @as(f64, hash(i, 0, 5))) * 2 * std.math.pi / count;
        const length = 10 + 26 * hash(i, 0, 6) * hash(i, 0, 12);
        var d = from;
        while (d < from + length) : (d += 2) {
            const k = (d - from) / length;
            const lit = 0.4 + 0.6 * twinkle(i, @intFromFloat(d), secs * 1.6);
            const a = (1 - k) * 0.65 * lit * g;
            if (a < 0.03) continue;
            const color = ray_colors[@as(usize, @intFromFloat(hash(i, @intFromFloat(d), 7) * ray_colors.len)) % ray_colors.len];
            const x = cx + d * @as(f32, @floatCast(@cos(angle)));
            const y = cy + d * @as(f32, @floatCast(@sin(angle)));
            c.roundRect(x - 0.5, y - 0.5, 1, 1, 0, .{ .solid = color }, a);
        }
    }
}

/// The ring of pixels bursting out of the brain, k into the burst.
fn burst(c: *Canvas, cx: f32, cy: f32, k: f32) void {
    if (k <= 0 or k >= 1) return;
    const count = 28;
    const e = 1 - std.math.pow(f32, 1 - k, 3);
    for (0..count) |i| {
        const angle = (@as(f64, @floatFromInt(i)) + 0.3 * @as(f64, hash(i, 1, 8))) * 2 * std.math.pi / count;
        const r = 11 + (6 + 12 * hash(i, 1, 9)) * e;
        const x = cx + r * @as(f32, @floatCast(@cos(angle))) * 1.05;
        const y = cy + r * @as(f32, @floatCast(@sin(angle))) * 0.95;
        c.roundRect(x - 1, y - 1, 2, 2, 0, .{ .solid = burst_colors[i % burst_colors.len] }, 1 - k * k);
    }
}

/// The pixels glinting on the brain.
fn sparkles(c: *Canvas, cx: f32, cy: f32, g: f32, secs: f64) void {
    for (0..10) |i| {
        const x = cx - 10 + 20 * hash(i, 2, 10);
        const y = cy - 9 + 18 * hash(i, 2, 11);
        const a = twinkle(i, 99, secs * 1.3) * g;
        if (a < 0.05) continue;
        c.roundRect(x - 0.75, y - 0.75, 1.5, 1.5, 0, .{ .solid = if (i % 3 == 0) 0x7dd3fc else 0xffffff }, a);
    }
}

const Paint = union(enum) {
    solid: u32,
    /// From `from` at x to `to` at x + width, each at its alpha.
    across: struct { x: f32, width: f32, from: u32, to: u32, from_alpha: f32, to_alpha: f32 },
    /// From the top left to the bottom right of a square.
    diagonal: struct { x: f32, y: f32, size: f32, from: u32, to: u32 },

    /// The color and opacity at (x, y) in DIPs.
    fn at(self: Paint, x: f32, y: f32) struct { u32, f32 } {
        return switch (self) {
            .solid => |color| .{ color, 1 },
            .across => |p| blk: {
                const k = std.math.clamp((x - p.x) / p.width, 0, 1);
                break :blk .{ mix(p.from, p.to, k), p.from_alpha + (p.to_alpha - p.from_alpha) * k };
            },
            .diagonal => |p| .{ mix(p.from, p.to, std.math.clamp(((x - p.x) + (y - p.y)) / (2 * p.size), 0, 1)), 1 },
        };
    }
};

/// Premultiplied BGRA pixels, `scale` to a DIP, with shapes antialiased by
/// their distance from each pixel's center.
const Canvas = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    scale: f32,

    fn clear(self: *Canvas, color: u32) void {
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) self.pixels[i..][0..4].* = .{ @truncate(color), @truncate(color >> 8), @truncate(color >> 16), 255 };
    }

    fn blend(self: *Canvas, x: usize, y: usize, color: u32, alpha: f32) void {
        if (alpha <= 0.002) return;
        const a = @min(1, alpha);
        const i = (y * self.width + x) * 4;
        const keep = 1 - a;
        inline for (.{ 0, 8, 16 }, 0..) |shift, c| {
            const source: f32 = @floatFromInt((color >> shift) & 0xff);
            self.pixels[i + c] = @intFromFloat(@min(255, source * a + @as(f32, @floatFromInt(self.pixels[i + c])) * keep + 0.5));
        }
        self.pixels[i + 3] = @intFromFloat(@min(255, 255 * a + @as(f32, @floatFromInt(self.pixels[i + 3])) * keep + 0.5));
    }

    /// The pixels a box in DIPs touches, grown by `margin` DIPs.
    fn box(self: *const Canvas, x: f32, y: f32, w: f32, h: f32, margin: f32) ?[4]usize {
        const left = @floor((x - margin) * self.scale);
        const top = @floor((y - margin) * self.scale);
        const right = @ceil((x + w + margin) * self.scale);
        const bottom = @ceil((y + h + margin) * self.scale);
        const fw: f32 = @floatFromInt(self.width);
        const fh: f32 = @floatFromInt(self.height);
        if (right <= 0 or bottom <= 0 or left >= fw or top >= fh) return null;
        return .{ @intFromFloat(@max(0, left)), @intFromFloat(@max(0, top)), @intFromFloat(@min(fw, right)), @intFromFloat(@min(fh, bottom)) };
    }

    /// Signed distance from (px, py) to a rounded rectangle, negative inside.
    fn distance(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, r: f32) f32 {
        const cx = x + w / 2;
        const cy = y + h / 2;
        const qx = @abs(px - cx) - (w / 2 - r);
        const qy = @abs(py - cy) - (h / 2 - r);
        const outside = @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0));
        return outside + @min(@max(qx, qy), 0) - r;
    }

    fn roundRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, paint: Paint, alpha: f32) void {
        if (alpha <= 0 or w <= 0 or h <= 0) return;
        const area = self.box(x, y, w, h, 1) orelse return;
        const half_pixel = 0.5 / self.scale;
        for (area[1]..area[3]) |py| for (area[0]..area[2]) |px| {
            const dx = (@as(f32, @floatFromInt(px)) + 0.5) / self.scale;
            const dy = (@as(f32, @floatFromInt(py)) + 0.5) / self.scale;
            // Pixels smaller than the shape cover by area; the distance
            // gives the edge.
            var cover = std.math.clamp(0.5 - distance(dx, dy, x, y, w, h, @min(r, @min(w, h) / 2)) * self.scale, 0, 1);
            if (w < 2 * half_pixel or h < 2 * half_pixel) cover *= @min(1, w * self.scale) * @min(1, h * self.scale);
            if (cover <= 0) continue;
            const color, const opacity = paint.at(dx, dy);
            self.blend(px, py, color, cover * opacity * alpha);
        };
    }

    fn ring(self: *Canvas, cx: f32, cy: f32, r: f32, width: f32, color: u32, alpha: f32) void {
        const area = self.box(cx - r, cy - r, 2 * r, 2 * r, width + 1) orelse return;
        for (area[1]..area[3]) |py| for (area[0]..area[2]) |px| {
            const dx = (@as(f32, @floatFromInt(px)) + 0.5) / self.scale - cx;
            const dy = (@as(f32, @floatFromInt(py)) + 0.5) / self.scale - cy;
            const d = @abs(@sqrt(dx * dx + dy * dy) - r) - width / 2;
            self.blend(px, py, color, std.math.clamp(0.5 - d * self.scale, 0, 1) * alpha);
        };
    }

    /// A box shadow of a rounded rectangle: black at `opacity`, blurred by
    /// `blur` and grown by `spread` DIPs.
    fn shadow(self: *Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, blur: f32, spread: f32, opacity: f32) void {
        const area = self.box(x - spread, y - spread, w + 2 * spread, h + 2 * spread, blur) orelse return;
        const sigma = blur / 2;
        for (area[1]..area[3]) |py| for (area[0]..area[2]) |px| {
            const dx = (@as(f32, @floatFromInt(px)) + 0.5) / self.scale;
            const dy = (@as(f32, @floatFromInt(py)) + 0.5) / self.scale;
            const d = distance(dx, dy, x - spread, y - spread, w + 2 * spread, h + 2 * spread, @max(0, r + spread));
            // Edge of a Gaussian blur: about the error function of the
            // distance.
            const k = 0.5 - 0.5 * std.math.tanh(d / sigma * 0.8);
            self.blend(px, py, 0, opacity * k);
        };
    }

    /// A soft round glow of `color`, radius `r` DIPs.
    fn glow(self: *Canvas, cx: f32, cy: f32, r: f32, color: u32, alpha: f32) void {
        if (alpha <= 0) return;
        const area = self.box(cx - r, cy - r, 2 * r, 2 * r, 0) orelse return;
        for (area[1]..area[3]) |py| for (area[0]..area[2]) |px| {
            const dx = ((@as(f32, @floatFromInt(px)) + 0.5) / self.scale - cx) / r;
            const dy = ((@as(f32, @floatFromInt(py)) + 0.5) / self.scale - cy) / r;
            const d2 = dx * dx + dy * dy;
            if (d2 >= 1) continue;
            self.blend(px, py, color, alpha * @exp(-d2 * 4.5) * (1 - d2));
        };
    }

    /// Paints through an 8-bit mask in this canvas's pixels.
    fn coverage(self: *Canvas, mask: ui.drawing.Coverage, paint: Paint, alpha: f32) void {
        for (0..mask.height) |row| for (0..mask.width) |col| {
            const value = mask.pixels[row * mask.stride + col];
            if (value == 0) continue;
            const px = @as(i64, mask.origin_x) + @as(i64, @intCast(col));
            const py = @as(i64, mask.origin_y) + @as(i64, @intCast(row));
            if (px < 0 or py < 0 or px >= self.width or py >= self.height) continue;
            const color, const opacity = paint.at((@as(f32, @floatFromInt(px)) + 0.5) / self.scale, (@as(f32, @floatFromInt(py)) + 0.5) / self.scale);
            self.blend(@intCast(px), @intCast(py), color, @as(f32, @floatFromInt(value)) / 255 * opacity * alpha);
        };
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var slider: Slider = .{};
    defer slider.picture.deinit();
    var storage: view.Storage(16, 256) = .{};
    var host = view.Host.init(&slider, Slider.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0) }, .background = page_color });
    slider.picture.host = &host;
    slider.picture.allocator = allocator;
    var timer = view_timer.Timer.init(&host);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Effort", .width = window_width, .height = window_height });
    try host.attach(window);
    try timer.attach(app, allocator);
    window.show();
    try app.run();
    try timer.close();
    slider.picture.host = null;
}

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};

test "the thumb follows a drag to the nearest level, eases when let go, and steps with keys" {
    var slider: Slider = .{};
    var storage: view.Storage(16, 256) = .{};
    var h = view.Harness.init(&slider, Slider.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = window_width, .height = window_height }, .options = .{ .root = .{ .padding = view.Insets.all(0) } } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    try std.testing.expectEqual([2]f32{ 126, card_y }, slider.origin);
    const at = struct {
        fn x(level: f32) f32 {
            return 126 + stop_x + stop_gap * level;
        }
    }.x;
    const y = card_y + brain_y;
    try h.press(at(0), y, .{});
    try h.moveTo(at(1.3), y);
    try std.testing.expectApproxEqAbs(@as(f64, 1.3), slider.thumb(slider.now)[0], 0.01);
    try std.testing.expectEqual(@as(usize, 1), slider.level);
    try h.moveTo(at(2.7), y);
    try std.testing.expectEqualStrings("Extra", levels[slider.level]);
    try h.release(at(2.7), y);
    const eased = slider.thumb(slider.now);
    try std.testing.expect(@abs(eased[0] - 2.7) < 0.01 and eased[1]);
    try h.advance(move_time);
    try std.testing.expectEqual(@as(f64, 3), slider.thumb(slider.now)[0]);

    _ = try h.key(.{ .key = .right });
    try std.testing.expectEqual(@as(usize, 4), slider.level);
    _ = try h.key(.{ .key = .home });
    try std.testing.expectEqual(@as(usize, 0), slider.level);
}

test "End goes Galaxy, whose effects come in and go when the slider leaves it" {
    var slider: Slider = .{};
    var storage: view.Storage(16, 256) = .{};
    var h = view.Harness.init(&slider, Slider.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = window_width, .height = window_height }, .options = .{ .root = .{ .padding = view.Insets.all(0) } } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    try h.clickAt(126 + stop_x, card_y + brain_y);
    _ = try h.key(.{ .key = .end });
    try std.testing.expectEqual(@as(usize, galaxy), slider.level);
    try std.testing.expectEqual(@as(f32, 0), slider.galaxyLevel(slider.now));
    try h.advance(std.time.ns_per_s);
    try std.testing.expectEqual(@as(f32, 1), slider.galaxyLevel(slider.now));
    _ = try h.key(.{ .key = .left });
    try h.advance(galaxy_out);
    try std.testing.expectEqual(@as(usize, 4), slider.level);
    try std.testing.expectEqual(@as(f32, 0), slider.galaxyLevel(slider.now));
}

test "CSS easing and the card's pixels" {
    try std.testing.expectEqual(@as(f64, 0), move_ease.at(0));
    try std.testing.expectEqual(@as(f64, 1), move_ease.at(1));
    try std.testing.expect(move_ease.at(0.2) > 0.6);
    var pixels: [40 * 20 * 4]u8 = undefined;
    var canvas: Canvas = .{ .pixels = &pixels, .width = 40, .height = 20, .scale = 1 };
    canvas.clear(page_color);
    canvas.roundRect(2, 2, 36, 16, 4, .{ .solid = 0xff0000 }, 1);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixels[(10 * 40 + 20) * 4 ..][0..4].*);
    try std.testing.expectEqual([4]u8{ 0x10, 0x10, 0x10, 255 }, pixels[0..4].*);
}
