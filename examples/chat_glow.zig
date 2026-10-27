//! An assistant's window, lit as Apple Intelligence lights its own: while
//! the assistant works, the window's edges glow in flowing colors, the
//! field to write in glows in its ring, and "Thinking…" shimmers; the
//! assistant's orb, a glass sphere of drifting light, quickens as it
//! thinks.
//!
//! Each glow is a pattern of its own for an app: a leaf that shows a
//! `ui.PixelImage` its app computes on the CPU every frame, pixel by pixel
//! as a fragment shader would. The edges' glow is a leaf of no size built
//! last, whose picture covers the window and lets the pointer through. The
//! replies are canned; Escape stops one.
//!
//! Run it with `zig build run-chat-glow`.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const text = @import("ziggurat_view_text");
const md = @import("ziggurat_markdown");
const mv = @import("ziggurat_markdown_view");

// How long the assistant thinks before it writes, in seconds, and how
// fast it writes.
const think_time: f64 = 1.6;
const words_per_second = 28;
// The glow comes up over fade_in seconds and goes over fade_out; the orb's
// liveliness follows the work over liven.
const fade_in: f64 = 0.35;
const fade_out: f64 = 0.9;
const liven: f64 = 0.5;
// The composer's ring: ring_padding DIPs of glow around the field, whose
// corners are field_radius.
const ring_padding = 12;
const field_radius = 16;
const max_width = 660;
const reply_size = 15;

const background: u32 = 0xffffff;
const surface: u32 = 0xf2f2f7;
const text_color: u32 = 0x1c1c1e;
const muted: u32 = 0x8e8e93;
const border: u32 = 0xd1d1d6;

const suggestions = [_][]const u8{ "Summarize my week", "Draft a reply to the team", "Plan three days in Kyoto" };

const Message = struct {
    mine: bool,
    /// The user's words, owned, or the reply's.
    text: []const u8,
    /// Bytes of the reply shown so far, at a word's end.
    shown: usize = 0,
    /// The reply stopped before it wrote.
    stopped: bool = false,
};

// The edge glow's colors, and how its stops move: every shuffle_every
// seconds they head for places of their own, picked at random, over
// shuffle_time, easing in and out.
const glow_colors = [_]u32{ 0xBC82F3, 0xF5B9EA, 0x8D9FFF, 0xFF6778, 0xFFBA71, 0xC686FF };
const shuffle_every = 0.5;
const shuffle_time = 1.0;

/// A stop of the gradient: its color in Oklab and where it lies around the
/// window, from 0 to 1.
const Stop = struct { l: f64, a: f64, b: f64, at: f64 };

const Stops = struct {
    from: [glow_colors.len]Stop,
    to: [glow_colors.len]Stop,
    since: f64 = 0,
    next: f64 = 0,

    fn init(random: std.Random) Stops {
        const to = shuffle(random);
        return .{ .from = to, .to = to };
    }

    /// The colors at places picked at random, in order around the window.
    fn shuffle(random: std.Random) [glow_colors.len]Stop {
        var out: [glow_colors.len]Stop = undefined;
        for (glow_colors, 0..) |color, i| {
            const lab = oklab(color);
            out[i] = .{ .l = lab[0], .a = lab[1], .b = lab[2], .at = random.float(f64) };
        }
        std.mem.sort(Stop, &out, {}, struct {
            fn less(_: void, x: Stop, y: Stop) bool {
                return x.at < y.at;
            }
        }.less);
        return out;
    }

    fn step(self: *Stops, now: f64, random: std.Random) void {
        if (now < self.next) return;
        self.from = self.show(now);
        self.to = shuffle(random);
        self.since = now;
        self.next = now + shuffle_every;
    }

    fn show(self: *const Stops, now: f64) [glow_colors.len]Stop {
        const k = ease(std.math.clamp((now - self.since) / shuffle_time, 0, 1));
        var out: [glow_colors.len]Stop = undefined;
        for (&out, self.from, self.to) |*o, f, to| o.* = .{ .l = f.l + (to.l - f.l) * k, .a = f.a + (to.a - f.a) * k, .b = f.b + (to.b - f.b) * k, .at = f.at + (to.at - f.at) * k };
        return out;
    }

    /// The color at `x` around the window, blended in Oklab, going round
    /// without a seam.
    fn colorAt(stops: []const Stop, x: f64) [3]f64 {
        const first = stops[0];
        const last = stops[stops.len - 1];
        var a = last;
        var b = first;
        var span = first.at + 1 - last.at;
        var into = if (x >= last.at) x - last.at else x + 1 - last.at;
        for (stops[0 .. stops.len - 1], stops[1..]) |p, q| if (x >= p.at and x < q.at) {
            a = p;
            b = q;
            span = q.at - p.at;
            into = x - p.at;
        };
        const k = if (span > 1e-6) into / span else 0;
        return srgb(a.l + (b.l - a.l) * k, a.a + (b.a - a.a) * k, a.b + (b.b - a.b) * k);
    }
};

fn ease(x: f64) f64 {
    return x * x * (3 - 2 * x);
}

/// The color of Oklab's (l, a, b) in sRGB, from 0 to 1.
fn srgb(l: f64, a: f64, b: f64) [3]f64 {
    var lc = l + 0.3963377774 * a + 0.2158037573 * b;
    var mc = l - 0.1055613458 * a - 0.0638541728 * b;
    var sc = l - 0.0894841775 * a - 1.2914855480 * b;
    lc = lc * lc * lc;
    mc = mc * mc * mc;
    sc = sc * sc * sc;
    const linear = [3]f64{ 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc, -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc, -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc };
    var out: [3]f64 = undefined;
    for (linear, 0..) |v, i| {
        const c = std.math.clamp(v, 0, 1);
        out[i] = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f64, c, 1.0 / 2.4) - 0.055;
    }
    return out;
}

/// `rgb` in Oklab.
fn oklab(rgb: u32) [3]f64 {
    var linear: [3]f64 = undefined;
    inline for (.{ 16, 8, 0 }, 0..) |shift, i| {
        const x = @as(f64, @floatFromInt((rgb >> shift) & 0xff)) / 255;
        linear[i] = if (x <= 0.04045) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4);
    }
    const lc = std.math.cbrt(0.4122214708 * linear[0] + 0.5363325363 * linear[1] + 0.0514459929 * linear[2]);
    const mc = std.math.cbrt(0.2119034982 * linear[0] + 0.6806995451 * linear[1] + 0.1073969566 * linear[2]);
    const sc = std.math.cbrt(0.0883024619 * linear[0] + 0.2817188376 * linear[1] + 0.6299787005 * linear[2]);
    return .{ 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc, 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc, 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc };
}

// What the shaders compute, a pixel at a time.

const Vec3 = [3]f64;

fn mix3(a: Vec3, b: Vec3, k: f64) Vec3 {
    return .{ a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k };
}

/// The glow's colors around a loop from 0 to 1: violet, pink, periwinkle,
/// purple, coral and peach.
fn palette(value: f64) Vec3 {
    const x = (value - @floor(value)) * 6;
    const colors = [_]Vec3{ .{ 0.74, 0.51, 0.95 }, .{ 0.96, 0.73, 0.92 }, .{ 0.55, 0.62, 1 }, .{ 0.67, 0.43, 0.93 }, .{ 1, 0.4, 0.47 }, .{ 1, 0.73, 0.44 } };
    const i: usize = @min(5, @as(usize, @intFromFloat(x)));
    return mix3(colors[i], colors[(i + 1) % 6], x - @as(f64, @floatFromInt(i)));
}

fn smoothstep(e0: f64, e1: f64, x: f64) f64 {
    const k = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return k * k * (3 - 2 * k);
}

/// Where (x, y), from the middle of a box, lies around its outline, from 0
/// to 1.
fn around(x: f64, y: f64) f64 {
    return std.math.atan2(y, x) / (2 * std.math.pi) + 0.5;
}

/// The distance from (x, y), from a rectangle's middle, to the rectangle of
/// half size (hx, hy) with corners of radius r: below zero inside.
fn roundRect(x: f64, y: f64, hx: f64, hy: f64, r: f64) f64 {
    const qx = @abs(x) - hx + r;
    const qy = @abs(y) - hy + r;
    return @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - r;
}

/// The orb at (x, y) in a box of `size` DIPs: premultiplied color and alpha.
fn orb(x: f64, y: f64, size: f64, phase: f64, energy: f64, pixel: f64) [4]f64 {
    const inner = size * 0.5 / 1.25;
    const u = (x - 0.5 * size) / inner;
    const v = (y - 0.5 * size) / inner;
    const r = @sqrt(u * u + v * v);
    const time = phase;
    if (r > 1) {
        const halo = @exp(-(r - 1) * 5) * (0.25 + 0.2 * energy) * smoothstep(1.25, 1.05, r);
        const c = palette(time * 0.05 + around(u, v));
        return .{ c[0] * halo, c[1] * halo, c[2] * halo, halo };
    }
    const depth = @sqrt(@max(1 - r * r, 0));
    // The light inside, folded about and drifting.
    var wx = u * (1.1 + 0.15 * depth);
    var wy = v * (1.1 + 0.15 * depth);
    const fold = 0.22 + 0.25 * energy;
    const fx = @sin(wy * 2.7 + time * 1.1);
    const fy = @cos(wx * 2.3 - time * 0.9);
    wx += fold * fx;
    wy += fold * fy;
    const gx = @sin(wy * 5.1 - time * 1.7);
    const gy = @cos(wx * 4.7 + time * 1.3);
    wx += 0.12 * gx;
    wy += 0.12 * gy;
    var col: Vec3 = .{ 0.07, 0.04, 0.18 };
    for (0..5) |i| {
        const f: f64 = @floatFromInt(i);
        const cx = 0.6 * @sin(time * (0.5 + 0.13 * f) + f * 2.1);
        const cy = 0.6 * @cos(time * (0.43 + 0.11 * f) + f * 1.3);
        const k = @exp(-((wx - cx) * (wx - cx) + (wy - cy) * (wy - cy)) * 3.4);
        const p = palette(f / 5 + time * 0.03);
        for (&col, p) |*c, q| c.* += q * k * 0.85;
    }
    // Glass: darker toward the rim inside, a colored rim, a highlight.
    const rim = std.math.pow(f64, 1 - depth, 2.6);
    const edge = palette(around(u, v) + time * 0.05);
    const light = [3]f64{ -0.45, -0.6, 0.66 };
    const length = @sqrt(light[0] * light[0] + light[1] * light[1] + light[2] * light[2]);
    const spec = std.math.pow(f64, @max((u * light[0] + v * light[1] + depth * light[2]) / length, 0), 60);
    const top = 0.06 * smoothstep(0.3, 1, -v * depth);
    const alpha = smoothstep(1, 1 - 1.5 / (inner * pixel), r);
    var out: [4]f64 = undefined;
    for (0..3) |i| out[i] = @min(1, col[i] * (0.7 + 0.4 * depth) + edge[i] * rim * 0.8 + spec * 0.7 + top) * alpha;
    out[3] = alpha;
    return out;
}

/// The composer's ring at (x, y) in a box of `w` by `h` DIPs.
fn ring(x: f64, y: f64, w: f64, h: f64, time: f64, strength: f64) [4]f64 {
    const px = x - 0.5 * w;
    const py = y - 0.5 * h;
    const dist = roundRect(px, py, 0.5 * w - ring_padding, 0.5 * h - ring_padding, field_radius) - 0.6;
    const flow = around(px / w, py / h) + time * 0.12;
    const line = @exp(-@abs(dist) / 0.9);
    const glow = if (dist > 0) (@exp(-dist / 6) * 0.55 + @exp(-dist / 16) * 0.25) * smoothstep(ring_padding, ring_padding * 0.3, dist) else 0;
    const alpha = std.math.clamp(line * (0.5 + 0.5 * strength) + glow * strength, 0, 1);
    const col = mix3(palette(flow), palette(flow + 0.2), glow / (line + glow + 0.0001));
    return .{ col[0] * alpha, col[1] * alpha, col[2] * alpha, alpha };
}

/// The edge glow's layers: the window's outline stroked inside its edge
/// this wide and blurred this much.
const glow_layers = [_][2]f64{ .{ 6, 0 }, .{ 9, 4 }, .{ 11, 12 }, .{ 15, 15 } };

/// How much of a band `width` DIPs deep inside the edge, blurred by
/// `sigma`, covers a point `depth` DIPs inside it.
fn band(depth: f64, width: f64, sigma: f64) f64 {
    if (sigma <= 0) return std.math.clamp(width - depth + 0.5, 0, 1) * std.math.clamp(depth + 0.5, 0, 1);
    const s = sigma * std.math.sqrt2;
    return 0.5 * (erf((width - depth) / s) - erf(-depth / s));
}

fn erf(x: f64) f64 {
    // Abramowitz and Stegun 7.1.26.
    const sign: f64 = if (x < 0) -1 else 1;
    const a = @abs(x);
    const k = 1 / (1 + 0.3275911 * a);
    const y = 1 - (((((1.061405429 * k - 1.453152027) * k) + 1.421413741) * k - 0.284496736) * k + 0.254829592) * k * @exp(-a * a);
    return sign * y;
}

const Kind = enum { orb, avatar, still, ring, edge };

/// A leaf whose picture its app computes each frame.
const Picture = struct {
    kind: Kind,
    chat: *Chat = undefined,
    image: ?ui.PixelImage = null,
    bounds: view.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// Painted this frame, so the next render draws it.
    painted: bool = false,
    /// The time the picture shows.
    drawn: ?f64 = null,

    fn embed(self: *Picture, chat: *Chat) view.Embed {
        self.chat = chat;
        return .{ .context = self, .measure = measure, .place = place, .paint = paint };
    }
    fn measure(ptr: *anyopaque, _: ui.Theme) view.layout.Measurement {
        const self: *Picture = @ptrCast(@alignCast(ptr));
        const size: view.Size = switch (self.kind) {
            .orb => .{ .width = 150, .height = 150 },
            .avatar, .still => .{ .width = 30, .height = 30 },
            .ring, .edge => .{ .width = 0, .height = 0 },
        };
        return .{ .minimum = size, .preferred = size };
    }
    fn place(ptr: *anyopaque, _: u64, bounds: view.Rect) void {
        const self: *Picture = @ptrCast(@alignCast(ptr));
        switch (self.kind) {
            .edge => {},
            // The ring's leaf starts the box around the field, stretched
            // to its height; the box ends where the end's marker lies.
            .ring => self.bounds = .{ .x = bounds.x - ring_padding, .y = bounds.y - ring_padding, .width = self.bounds.width, .height = bounds.height + 2 * ring_padding },
            else => self.bounds = bounds,
        }
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, _: u64, _: view.Rect) anyerror!void {
        const self: *Picture = @ptrCast(@alignCast(ptr));
        const chat = self.chat;
        chat.scale = frame.size.scale;
        if (self.kind == .ring) self.bounds.width = chat.ring_end + ring_padding - self.bounds.x;
        if (self.kind == .edge) self.bounds = .{ .x = 0, .y = 0, .width = @as(f32, @floatFromInt(frame.size.width)) / frame.size.scale, .height = @as(f32, @floatFromInt(frame.size.height)) / frame.size.scale };
        self.painted = true;
        const shows = self.kind != .edge or chat.glow > 0.001;
        if (shows) if (self.image) |*image| if (image.view()) |picture| try frame.image(self.bounds, picture, .{});
        chat.requestRender();
    }

    /// Pixels per DIP: the edge's glow is soft, so half as many do.
    fn density(self: *const Picture, scale: f32) f32 {
        return if (self.kind == .edge) 0.5 else scale;
    }

    fn render(self: *Picture, context: *ui.Context) void {
        const chat = self.chat;
        if (self.kind == .edge and chat.glow <= 0.001) return self.release(context);
        if (self.kind == .still and self.drawn != null) return;
        if (self.drawn) |drawn| if (drawn == chat.now and self.kind != .still) return;
        const scale = self.density(chat.scale);
        const width: u32 = @intFromFloat(@max(1, @round(self.bounds.width * scale)));
        const height: u32 = @intFromFloat(@max(1, @round(self.bounds.height * scale)));
        if (self.bounds.width < 1 or self.bounds.height < 1) return;
        if (self.image) |*image| if (image.width != width or image.height != height) {
            self.release(context);
            image.deinit();
            self.image = null;
        };
        if (self.image == null) self.image = ui.PixelImage.init(chat.allocator, width, height) catch return;
        const image = &self.image.?;
        self.fill(image.pixels(), width, height, scale);
        image.commit(context) catch |err| return std.log.err("glow: {s}", .{@errorName(err)});
        self.drawn = chat.now;
    }

    fn release(self: *Picture, context: *ui.Context) void {
        if (self.image) |*image| image.release(context);
        self.drawn = null;
    }

    fn fill(self: *Picture, pixels: []u8, width: u32, height: u32, scale: f32) void {
        const chat = self.chat;
        const w: f64 = self.bounds.width;
        const h: f64 = self.bounds.height;
        const stops = chat.stops.show(chat.now);
        const strength = 0.25 + 0.75 * ease(chat.glow);
        const fade = ease(chat.glow);
        for (0..height) |row| for (0..width) |col| {
            const x = (@as(f64, @floatFromInt(col)) + 0.5) / scale;
            const y = (@as(f64, @floatFromInt(row)) + 0.5) / scale;
            const color: [4]f64 = switch (self.kind) {
                .orb, .avatar => orb(x, y, w, chat.orb_phase, chat.energy, scale),
                .still => orb(x, y, w, 1.7, 0, scale),
                .ring => ring(x, y, w, h, chat.now, strength),
                .edge => edge: {
                    // How deep inside the window's rounded outline.
                    const depth = -roundRect(x - w / 2, y - h / 2, w / 2, h / 2, 10);
                    if (depth > 70) break :edge .{ 0, 0, 0, 0 };
                    var clear: f64 = 1;
                    for (glow_layers) |layer| clear *= 1 - band(depth, layer[0], 0.95 * layer[1]);
                    const alpha = (1 - clear) * fade;
                    // Around from the top, as the conic gradient goes.
                    const c = Stops.colorAt(&stops, @mod(around(x - w / 2, y - h / 2) + 0.25, 1));
                    break :edge .{ c[0] * alpha, c[1] * alpha, c[2] * alpha, alpha };
                },
            };
            const i = (row * width + col) * 4;
            pixels[i] = @intFromFloat(@round(std.math.clamp(color[2], 0, 1) * 255));
            pixels[i + 1] = @intFromFloat(@round(std.math.clamp(color[1], 0, 1) * 255));
            pixels[i + 2] = @intFromFloat(@round(std.math.clamp(color[0], 0, 1) * 255));
            pixels[i + 3] = @intFromFloat(@round(std.math.clamp(color[3], 0, 1) * 255));
        };
    }
};

const Chat = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    messages: std.ArrayList(Message) = .empty,
    replies: usize = 0,
    /// The conversation's clock, in seconds; when the last message was
    /// asked, when the assistant began to write (0 before), and whether it
    /// works.
    now: f64 = 0,
    asked: f64 = 0,
    writing: f64 = 0,
    busy: bool = false,
    last: ?u64 = null,
    /// How much the window's edges glow, how lively the orb is, and how
    /// far its colors have moved.
    glow: f64 = 0,
    energy: f64 = 0,
    orb_phase: f64 = 0,
    still: bool = false,
    stops: Stops,
    list: view.ScrollModel = .{},
    follow: bool = true,
    last_offset: f32 = 0,
    input: ?*text.TextField = null,
    draft: [512]u8 = undefined,
    draft_len: usize = 0,
    send_queued: bool = false,
    host: ?*view.Host = null,
    scale: f32 = 1,
    render_queued: bool = false,
    /// Where the box around the field ends inside its padding.
    ring_end: f32 = 0,
    pictures: struct {
        orb: Picture = .{ .kind = .orb },
        avatar: Picture = .{ .kind = .avatar },
        still: Picture = .{ .kind = .still },
        ring: Picture = .{ .kind = .ring },
        edge: Picture = .{ .kind = .edge },
    } = .{},
    markdown: md.Storage(256, 4096) = .{},

    fn init(allocator: std.mem.Allocator) Chat {
        var rng: std.Random.DefaultPrng = .init(std.crypto.random.int(u64));
        return .{ .allocator = allocator, .stops = .init(rng.random()), .rng = rng };
    }
    fn deinit(self: *Chat) void {
        for (self.messages.items) |item| if (item.mine) self.allocator.free(item.text);
        self.messages.deinit(self.allocator);
        inline for (std.meta.fields(@TypeOf(self.pictures))) |field| if (@field(self.pictures, field.name).image) |*image| image.deinit();
    }

    /// Moves the conversation on by dt seconds: the assistant thinks, then
    /// writes word by word; the glow and the orb follow its work.
    fn step(self: *Chat, dt: f64) void {
        self.now += dt;
        if (self.busy) {
            const m = &self.messages.items[self.messages.items.len - 1];
            // It began to write as it stopped thinking, however late the
            // clock tells.
            if (self.writing == 0 and self.now - self.asked >= think_time) self.writing = self.asked + think_time;
            if (self.writing > 0) {
                const words: usize = @intFromFloat((self.now - self.writing) * words_per_second + 1);
                m.shown = wordsEnd(m.text, words);
                if (m.shown == m.text.len) self.busy = false;
            }
        }
        self.glow = if (self.busy) @min(1, self.glow + dt / fade_in) else @max(0, self.glow - dt / fade_out);
        const goal: f64 = if (self.busy) 1 else 0;
        self.energy += (goal - self.energy) * (1 - @exp(-dt / liven));
        if (self.glow > 0 and !self.still) self.stops.step(self.now, self.rng.random());
        if (!self.still) self.orb_phase += dt * (0.5 + 1.8 * self.energy);
    }

    /// Something moves on its own: the assistant's work, the glow fading,
    /// the orb calming down, or the welcome's orb.
    fn moving(self: *const Chat) bool {
        return self.busy or self.glow > 0 or self.energy > 0.01 or (self.messages.items.len == 0 and !self.still);
    }

    fn send(self: *Chat, words: []const u8) void {
        const trimmed = std.mem.trim(u8, words, " \t\r\n");
        if (trimmed.len == 0) return;
        const owned = self.allocator.dupe(u8, trimmed) catch return;
        self.messages.ensureUnusedCapacity(self.allocator, 2) catch return self.allocator.free(owned);
        self.messages.appendAssumeCapacity(.{ .mine = true, .text = owned });
        self.messages.appendAssumeCapacity(.{ .mine = false, .text = replies[self.replies % replies.len] });
        self.replies += 1;
        self.draft_len = 0;
        self.asked = self.now;
        self.writing = 0;
        self.busy = true;
        self.follow = true;
    }

    /// The assistant stops where it is.
    fn stop(self: *Chat) void {
        self.busy = false;
        if (self.messages.items.len == 0) return;
        const m = &self.messages.items[self.messages.items.len - 1];
        if (!m.mine and m.shown == 0) m.stopped = true;
    }

    fn build(self: *Chat, v: *view.View) anyerror!void {
        self.still = v.preferences.reduce_motion;
        const time = v.time();
        if (self.last) |last| self.step(@as(f64, @floatFromInt(time -| last)) / std.time.ns_per_s);
        self.last = time;
        if (self.moving()) v.wakeAt(time + std.time.ns_per_s / 60);
        try v.bindKey(.{ .key = .escape }, true, 1);
        if (v.takeEvent(1) != null and self.busy) self.stop();

        try v.column(.{ .grow = 1, .self_align = .stretch, .background = background });
        if (self.messages.items.len == 0) try self.welcome(v) else try self.conversation(v);
        try self.composer(v);
        try v.end();
        // The edges' glow, over everything, which the pointer goes through.
        try v.embed(self.pictures.edge.embed(self), .{ .key = 9 });
    }

    fn welcome(self: *Chat, v: *view.View) !void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .alignment = .center, .justify = .center, .gap = 10, .padding = .{ .top = 40, .left = 24, .right = 24 } });
        try v.embed(self.pictures.orb.embed(self), .{ .key = 2, .name = "Assistant" });
        try v.text("How can I help?", .{ .font = .{ .size = 28, .weight = .semibold }, .color = text_color });
        try v.text("Ask anything, or start with one of these.", .{ .color = muted, .font = .{ .size = 14 } });
        try v.row(.{ .gap = 8, .justify = .center });
        for (suggestions, 0..) |suggestion, i| {
            if (try v.button(suggestion, .{ .key = 20 + i })) self.send(suggestion);
        }
        try v.end();
        try v.end();
    }

    fn conversation(self: *Chat, v: *view.View) !void {
        try v.scroll(&self.list, .{ .grow = 1, .self_align = .stretch, .padding = .{ .top = 52, .bottom = 16, .left = 24, .right = 24 }, .gap = 22, .key = 3, .alignment = .center });
        const end = self.list.maxOffset().y;
        if (self.list.offset.y + 0.5 < self.last_offset) self.follow = false;
        if (self.list.offset.y >= end - 2) self.follow = true;
        if (self.follow and self.list.offset.y < end) _ = self.list.setOffset(.{ .x = 0, .y = end }) catch {};
        self.last_offset = self.list.offset.y;
        for (self.messages.items, 0..) |*item, i| {
            try v.column(.{ .key = 100 + i, .self_align = .center, .width = max_width, .shrink = 1 });
            try self.message(v, item, i == self.messages.items.len - 1);
            try v.end();
        }
        try v.end();
    }

    fn message(self: *Chat, v: *view.View, m: *const Message, last: bool) !void {
        if (m.mine) {
            try v.row(.{ .self_align = .stretch });
            try v.spacer(.{});
            try v.row(.{ .padding = .{ .top = 9, .bottom = 9, .left = 14, .right = 14 }, .radius = 18, .background = surface, .max_width = 460, .shrink = 0 });
            // The view measures text by estimate; room to spare keeps short
            // words from being cut.
            const estimate = (view.Measurer{}).textSize(m.text, null).width;
            try v.text(m.text, .{ .min_width = @min(432, estimate * 1.25) });
            try v.end();
            try v.end();
            return;
        }
        try v.row(.{ .gap = 12, .alignment = .start, .self_align = .stretch });
        if (last) try v.embed(self.pictures.avatar.embed(self), .{ .key = 4 }) else try v.embed(self.pictures.still.embed(self), .{});
        if (m.stopped) {
            try v.text("Stopped.", .{ .color = text_color, .font = .{ .size = reply_size } });
        } else if (m.shown == 0 and last and self.busy) {
            // A shine sweeping across "Thinking…": its color brightens and
            // dims as the band passes.
            const s = (self.now * 0.6 - @floor(self.now * 0.6)) * 2.2 - 0.6;
            const k = @exp(-(0.4 - s) * (0.4 - s) * 14);
            try v.text("Thinking…", .{ .color = mixColor(muted, text_color, k), .font = .{ .size = reply_size }, .name = "Thinking" });
        } else {
            const tree = md.parse(m.text[0..m.shown], self.markdown.buffers()) catch return v.text(m.text[0..m.shown], .{});
            _ = try mv.build(v, tree, .{ .width = max_width - 42 }, .{ .grow = 1 });
        }
        try v.end();
    }

    fn composer(self: *Chat, v: *view.View) !void {
        try v.row(.{ .justify = .center, .self_align = .stretch, .padding = .{ .left = 24 - ring_padding, .right = 24 - ring_padding, .bottom = 22 - ring_padding } });
        // The ring is drawn under the field: a leaf of no width placed
        // first, whose picture covers the box around the field, and a
        // marker last that tells where the box ends.
        try v.row(.{ .grow = 1, .max_width = max_width + 2 * ring_padding, .padding = view.Insets.all(ring_padding), .key = 5 });
        try v.embed(self.pictures.ring.embed(self), .{ .key = 10, .self_align = .stretch });
        try v.row(.{ .grow = 1, .alignment = .center, .gap = 8, .padding = .{ .top = 6, .bottom = 6, .left = 16, .right = 6 }, .radius = field_radius, .background = surface });
        if (self.input) |input| try v.embed(input.embed(), .{ .grow = 1, .key = 6 }) else try v.spacer(.{});
        if (self.busy) {
            if (try v.button("Stop", .{ .key = 7 })) self.stop();
        } else if (try v.button("Send", .{ .key = 8, .enabled = std.mem.trim(u8, self.draft[0..self.draft_len], " \t\r\n").len > 0 })) self.requestSend();
        try v.end();
        try v.embed(.{ .context = self, .measure = endMeasure, .place = endPlace, .paint = endPaint }, .{ .key = 11 });
        try v.end();
        try v.end();
    }

    fn endMeasure(_: *anyopaque, _: ui.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 0, .height = 0 }, .preferred = .{ .width = 0, .height = 0 } };
    }
    fn endPaint(_: *anyopaque, _: *ui.Frame, _: u64, _: view.Rect) anyerror!void {}
    fn endPlace(ptr: *anyopaque, _: u64, bounds: view.Rect) void {
        const self: *Chat = @ptrCast(@alignCast(ptr));
        self.ring_end = bounds.x;
    }

    fn requestSend(self: *Chat) void {
        const input = self.input orelse return self.send(self.draft[0..self.draft_len]);
        if (self.send_queued) return;
        const window = input.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = sendFromInput }) catch return;
        self.send_queued = true;
    }

    fn sendFromInput(ptr: *anyopaque) void {
        const self: *Chat = @ptrCast(@alignCast(ptr));
        self.send_queued = false;
        if (self.busy) return;
        self.send(self.draft[0..self.draft_len]);
        if (self.input) |input| {
            _ = input.field.setValue("") catch {};
            if (input.host.context.window) |window| window.invalidate();
        }
    }

    fn changed(ptr: ?*anyopaque, _: z.Window, _: u64) void {
        const self: *Chat = @ptrCast(@alignCast(ptr.?));
        const input = self.input orelse return;
        const document = input.field.document;
        const length = document.byteLength() catch return;
        var end = document.read(.{ .start = 0, .end = @min(length, self.draft.len) }, &self.draft) catch return;
        while (end > 0 and end < length and self.draft[end] & 0xc0 == 0x80) end -= 1;
        self.draft_len = end;
    }

    fn submitted(ptr: ?*anyopaque, _: z.Window) void {
        const self: *Chat = @ptrCast(@alignCast(ptr.?));
        if (!self.busy) self.requestSend();
    }

    /// The pictures painted this frame are drawn again after it.
    fn requestRender(self: *Chat) void {
        if (self.render_queued) return;
        const host = self.host orelse return;
        const window = host.context.window orelse return;
        window.app.post(.{ .context = self, .call = render }) catch return;
        self.render_queued = true;
    }

    fn render(ptr: *anyopaque) void {
        const self: *Chat = @ptrCast(@alignCast(ptr));
        self.render_queued = false;
        const host = self.host orelse return;
        const window = host.context.window orelse return;
        var changed_any = false;
        inline for (std.meta.fields(@TypeOf(self.pictures))) |field| {
            const picture = &@field(self.pictures, field.name);
            if (picture.painted) {
                const before = picture.drawn;
                picture.render(&host.context);
                changed_any = changed_any or !std.meta.eql(before, picture.drawn);
            }
            picture.painted = false;
        }
        if (changed_any) window.invalidate();
    }
};

fn mixColor(a: u32, b: u32, k: f64) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const x: f64 = @floatFromInt((a >> shift) & 0xff);
        const y: f64 = @floatFromInt((b >> shift) & 0xff);
        out |= @as(u32, @intFromFloat(@round(x + (y - x) * std.math.clamp(k, 0, 1)))) << shift;
    }
    return out;
}

/// The end of the first `count` words of `source`, each with the spaces
/// after it.
fn wordsEnd(source: []const u8, count: usize) usize {
    var words: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        while (i < source.len and source[i] != ' ' and source[i] != '\n') i += 1;
        while (i < source.len and (source[i] == ' ' or source[i] == '\n')) i += 1;
        words += 1;
        if (words == count) return i;
    }
    return source.len;
}

const replies = [_][]const u8{
    "Here's your week at a glance.\n\nYou shipped the new onboarding flow on Tuesday, and sign-ups are up 18% since. Thursday's design review settled the navigation question: tabs stay, the sidebar goes. Two things still need you: the Q3 budget draft is due Monday, and Priya is waiting on your feedback for the pricing page.",
    "Here's a draft:\n\nHi all, thanks for pushing through this sprint. The release is on track for Friday; the remaining risk is the migration, which Sam is testing tonight. If anything slips, we'll cut the export feature and ship it the week after. Let's keep tomorrow's stand-up to ten minutes.",
    "Day 1: Higashiyama. Start at Kiyomizu-dera early, walk down Sannenzaka to Gion, and end with dinner in Pontocho.\n\nDay 2: Arashiyama. The bamboo grove at sunrise, Tenryu-ji's garden, then the river by boat.\n\nDay 3: Fushimi Inari before the crowds, sake tasting in Fushimi, and a last evening at Nishiki Market.",
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var chat: Chat = .init(allocator);
    defer chat.deinit();
    var storage: view.Storage(1024, 32 * 1024) = .{};
    var host = view.Host.init(&chat, Chat.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0) }, .background = background });
    chat.host = &host;
    var timer = view_timer.Timer.init(&host);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch {};
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "", .{});
    defer document.close() catch {};

    const window = try app.createWindow(.{ .title = "Chat Glow", .width = 860, .height = 700, .min_width = 520, .min_height = 420 });
    try host.attach(window);
    try host.context.prepareTextFields(allocator, .{});
    try timer.attach(app, allocator);
    const field = try editing.Field.create(allocator, document, engine, .{ .value_bytes = chat.draft.len, .context = &chat, .changed = Chat.changed, .submit = Chat.submitted });
    var input = text.TextField.init(field, &host, .{ .font = .{ .size = 15 }, .scale = (try window.contentSize()).scale }, .{ .name = "Message", .frame = false });
    chat.input = &input;

    window.show();
    try app.run();
    chat.input = null;
    input.detach();
    try field.close();
    try timer.close();
    chat.host = null;
}

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};

fn harness(chat: *Chat, storage: anytype) view.Harness {
    return view.Harness.init(chat, Chat.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 860, .height = 700 }, .options = .{ .root = .{ .padding = view.Insets.all(0) } } });
}

test "a suggestion asks; the assistant thinks, glowing, writes, and the glow fades" {
    var chat: Chat = .init(std.testing.allocator);
    defer chat.deinit();
    var storage: view.Storage(1024, 32 * 1024) = .{};
    var h = harness(&chat, &storage);
    try h.render();
    try h.click(.{ .text = "Summarize my week" });
    try std.testing.expect(chat.messages.items.len == 2 and chat.busy);
    try h.render();
    _ = try h.find(.{ .text = "Summarize my week" });
    _ = try h.find(.{ .name = "Thinking" });
    const reply = &chat.messages.items[1];
    chat.step(think_time / 2);
    try std.testing.expect(reply.shown == 0 and chat.glow > 0);
    chat.step(think_time / 2);
    chat.step(0.1);
    try std.testing.expect(reply.shown > 0 and reply.shown < reply.text.len);
    for (0..200) |_| chat.step(0.05);
    try std.testing.expect(!chat.busy and reply.shown == reply.text.len and chat.glow == 0);
    try h.render();
    _ = try h.find(.{ .text = "Here's your week at a glance." });
}

test "Send asks what was written; Escape stops the assistant while it thinks" {
    var chat: Chat = .init(std.testing.allocator);
    defer chat.deinit();
    var storage: view.Storage(1024, 32 * 1024) = .{};
    var h = harness(&chat, &storage);
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    @memcpy(chat.draft[0..11], "Hello there");
    chat.draft_len = 11;
    try h.render();
    try h.click(.{ .text = "Send" });
    try std.testing.expectEqualStrings("Hello there", chat.messages.items[0].text);
    try std.testing.expectEqual(@as(usize, 0), chat.draft_len);
    _ = try h.key(.{ .key = .escape });
    try std.testing.expect(!chat.busy and chat.messages.items[1].stopped);
    try h.render();
    _ = try h.find(.{ .text = "Stopped." });
}

test "words end after their spaces, and the glow's pixels" {
    try std.testing.expectEqual(@as(usize, 4), wordsEnd("one two", 1));
    try std.testing.expectEqual(@as(usize, 6), wordsEnd("a  b\n\nc ", 2));
    try std.testing.expectEqual(@as(usize, 3), wordsEnd("one", 5));
    // The orb's middle is opaque, its corners clear but for the halo.
    const middle = orb(75, 75, 150, 0, 0, 1);
    try std.testing.expectEqual(@as(f64, 1), middle[3]);
    try std.testing.expect(orb(0, 0, 150, 0, 0, 1)[3] < 0.05);
    // The edge glows on the edge, not in the middle.
    try std.testing.expect(band(1, 6, 0) == 1 and band(70, 15, 0.95 * 15) < 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8427), erf(1), 1e-3);
    const lab = oklab(0xBC82F3);
    const back = srgb(lab[0], lab[1], lab[2]);
    try std.testing.expectApproxEqAbs(@as(f64, 0xBC) / 255, back[0], 1e-3);
}
