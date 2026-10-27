//! A black hole and its accretion disk, every pixel's ray of light traced
//! back through the hole's gravity on the CPU: the disk's far side shows
//! above and below the shadow, the side turning toward the camera blazes
//! brighter and bluer, and the stars behind smear into arcs around an
//! Einstein ring.
//!
//! Drag to orbit, scroll to come closer. A thread of its own draws a frame
//! in three passes, with helpers sharing the rows: the scene, its brightest
//! light blurred into a picture a quarter its size, and both together with
//! a lens's color fringes and a film's grain. The window shows the result
//! as a `ui.PixelImage` stretched over it. The scene renders at a
//! resolution of its own, which drops while frames take too long and rises
//! again once they keep up, as games do.
//!
//! Run it with `zig build run-blackhole`.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");

// The camera's distances from the hole, in its radii: nearest, at rest and
// farthest (within the escape, 42); and its pitch's bounds, short of the
// poles.
const near: f64 = 8;
const rest: f64 = 22;
const far: f64 = 36;
const max_pitch: f64 = 1.4;
// How fast the camera circles on its own, in radians a second, and how
// quickly a throw slows to it, a second.
const orbit_speed: f64 = 0.025;
const settle: f64 = 1.2;
// The scene's resolution, a fraction of the window's pixels across, from
// min_quality to max_quality: it drops by a step while frames take longer
// than slow_frame to draw, and rises once they take less than fast_frame
// for a while. The glow renders at 1 / glow_scale of it.
const min_quality: f64 = 0.125;
const max_quality: f64 = 0.5;
const quality_step: f64 = 0.0625;
const slow_frame: f64 = 1.0 / 30.0;
const fast_frame: f64 = 1.0 / 70.0;
const glow_scale = 4;
// The camera's focal length, in heights of the view.
const focal: f64 = 1.5;

const white: u32 = 0xebebeb;
const muted: u32 = 0x808080;

const Vec3 = @Vector(3, f64);

fn v3(x: f64, y: f64, w: f64) Vec3 {
    return .{ x, y, w };
}
fn splat(x: f64) Vec3 {
    return @splat(x);
}
fn dot(a: Vec3, b: Vec3) f64 {
    return @reduce(.Add, a * b);
}
fn norm(a: Vec3) Vec3 {
    return a * splat(1 / @sqrt(dot(a, a)));
}
fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn mix(a: Vec3, b: Vec3, k: f64) Vec3 {
    return a + (b - a) * splat(k);
}
fn mixf(a: f64, b: f64, k: f64) f64 {
    return a + (b - a) * k;
}
fn smoothstep(e0: f64, e1: f64, x: f64) f64 {
    const k = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return k * k * (3 - 2 * k);
}

/// The camera orbits the hole: its angles about the disk's axis (yaw) and
/// above the disk (pitch), in radians, its distance, and how fast the
/// angles turn on their own, after a drag's throw.
const Camera = struct {
    yaw: f64,
    pitch: f64,
    dist: f64,
    spin_yaw: f64 = 0,
    spin_pitch: f64 = 0,

    const Axes = struct { eye: Vec3, right: Vec3, up: Vec3, forward: Vec3 };

    /// Where the camera is and its right, up and forward axes, y up.
    fn axes(self: Camera) Axes {
        const cp = @cos(self.pitch);
        const eye = v3(cp * @sin(self.yaw), @sin(self.pitch), cp * @cos(self.yaw)) * splat(self.dist);
        const forward = norm(-eye);
        const right = norm(cross(forward, v3(0, 1, 0)));
        return .{ .eye = eye, .right = right, .up = cross(right, forward), .forward = forward };
    }

    /// Whether the camera still turns on its own.
    fn spinning(self: Camera) bool {
        return @abs(self.spin_yaw) > 1e-3 or @abs(self.spin_pitch) > 1e-3;
    }
};

// The scene, as the light from it reaches the camera: each pixel's ray is
// traced backward, bent by the hole's gravity (Schwarzschild's, in units of
// its radius), through the disk, which it may cross several times, above
// and below, to the stars or into the hole.

const disk_in = 2.6;
const disk_out = 13.0;
const escape = 42.0;

fn pcg(v: u32) u32 {
    const s = v *% 747796405 +% 2891336453;
    const w = ((s >> @intCast((s >> 28) + 4)) ^ s) *% 277803737;
    return (w >> 22) ^ w;
}

fn lattice(x: f64) u32 {
    return @bitCast(@as(i32, @intFromFloat(x)));
}

/// A number from 0 to 1 for a point of the integer lattice.
fn hash13(p: Vec3) f64 {
    const h = pcg(lattice(p[0]) ^ pcg(lattice(p[1]) ^ pcg(lattice(p[2]))));
    return @as(f64, @floatFromInt(h >> 8)) * (1.0 / 16777216.0);
}

/// Value noise from 0 to 1.
fn noise(p: Vec3) f64 {
    const i = @floor(p);
    var f = p - i;
    f = f * f * (splat(3) - splat(2) * f);
    return mixf(
        mixf(mixf(hash13(i), hash13(i + v3(1, 0, 0)), f[0]), mixf(hash13(i + v3(0, 1, 0)), hash13(i + v3(1, 1, 0)), f[0]), f[1]),
        mixf(mixf(hash13(i + v3(0, 0, 1)), hash13(i + v3(1, 0, 1)), f[0]), mixf(hash13(i + v3(0, 1, 1)), hash13(i + v3(1, 1, 1)), f[0]), f[1]),
        f[2],
    );
}

fn fbm(start: Vec3) f64 {
    var p = start;
    var s: f64 = 0;
    var a: f64 = 0.5;
    for (0..5) |_| {
        s += a * noise(p);
        p = p * splat(2.03) + splat(17.1);
        a *= 0.5;
    }
    return s;
}

/// The color of gas at a temperature from 0 (cool, deep red) to 1 (hot,
/// blue white).
fn blackbody(t: f64) Vec3 {
    var c = mix(v3(1, 0.16, 0.02), v3(1, 0.5, 0.15), smoothstep(0, 0.3, t));
    c = mix(c, v3(1, 0.84, 0.62), smoothstep(0.25, 0.65, t));
    return mix(c, v3(0.78, 0.86, 1), smoothstep(0.7, 1, t));
}

/// The light of the disk where a ray along d crosses it at p, and how dense
/// the gas is there.
fn disk(time: f64, p: Vec3, d: Vec3) [4]f64 {
    const r = @sqrt(p[0] * p[0] + p[2] * p[2]);
    if (r < disk_in or r > disk_out) return .{ 0, 0, 0, 0 };
    // The gas orbits, faster inside, and its streaks shear along.
    const a = -time * 1.6 * std.math.pow(f64, r, -1.5);
    const c = @cos(a);
    const s = @sin(a);
    const qx = c * p[0] - s * p[2];
    const qy = s * p[0] + c * p[2];
    const ang = std.math.atan2(qy, qx);
    const streaks = fbm(v3(1.3 * @cos(ang), 1.3 * @sin(ang), r * 3.2));
    const clumps = fbm(v3(qx * 0.8, qy * 0.8, r * 0.5 + 3));
    var dens = smoothstep(disk_in, disk_in + 0.4, r) * std.math.pow(f64, smoothstep(disk_out, disk_in, r), 1.6);
    dens *= std.math.clamp(0.15 + 1.6 * streaks * streaks * (0.4 + clumps), 0, 1.4);

    const t = std.math.clamp(std.math.pow(f64, disk_in / r, 1.05), 0, 1);
    var col = blackbody(t) * splat(0.12 + 4.5 * t * t * t);
    // Doppler beaming: the side coming toward the camera is brighter and
    // bluer, the side going away dimmer and redder; light climbing out of
    // the well loses some too.
    const v = @min(@sqrt(0.5 / (r - 1)), 0.62);
    const toward = dot(norm(v3(-p[2], 0, p[0])), -d);
    const doppler = @sqrt(1 - v * v) / (1 - v * toward);
    const shift = doppler * @sqrt(1 - 1 / r);
    col *= splat(std.math.pow(f64, shift, 2.4));
    col = mix(col * v3(1.15, 0.75, 0.55), col * v3(0.8, 0.92, 1.25), smoothstep(0.7, 1.3, shift));
    return .{ col[0], col[1], col[2], dens };
}

/// The light coming from far away along d: a galaxy's band of dust and
/// glow, and stars.
fn sky(d: Vec3) Vec3 {
    var col = v3(0.002, 0.0025, 0.005);
    const b = dot(d, norm(v3(0.25, 1, 0.35)));
    const neb = fbm(d * splat(3.2) + splat(10));
    const dust = fbm(d * splat(8) - splat(3));
    const band = @exp(-b * b * 10) * (0.3 + neb);
    col += mix(v3(0.07, 0.05, 0.12), v3(0.2, 0.13, 0.08), dust) * splat(band * 0.55);
    col *= splat(1 - 0.75 * @exp(-b * b * 60) * smoothstep(0.42, 0.65, dust));
    for (0..2) |layer| {
        const lf: f64 = @floatFromInt(layer);
        const g = d * splat(110 + 160 * lf);
        const cell = @floor(g);
        const h = hash13(cell + splat(lf * 1000));
        const th = 0.94 - 0.03 * band;
        if (h > th) {
            const off = splat(0.25) + v3(hash13(cell + v3(7, 0, 0)), hash13(cell + v3(0, 3, 0)), hash13(cell + v3(0, 0, 11))) * splat(0.5);
            const e = g - cell - off;
            const k = (h - th) / (1 - th);
            const tint = mix(v3(1, 0.75, 0.55), v3(0.7, 0.82, 1), hash13(cell + v3(5, 5, 0)));
            col += tint * splat(k * k * k * 7 * @exp(-dot(e, e) * 260));
        }
    }
    return col;
}

fn aces(x: Vec3) Vec3 {
    const y = (x * (splat(2.51) * x + splat(0.03))) / (x * (splat(2.43) * x + splat(0.59)) + splat(0.14));
    return @max(splat(0), @min(splat(1), y));
}

/// What a frame shows: the disk's time and the camera.
const Shot = struct {
    time: f64,
    camera: Camera,
};

/// The light reaching the camera through the pixel at (x, y) of a picture
/// `width` by `height`, its colors from 0 to 1.
fn trace(shot: Shot, axes: Camera.Axes, x: f64, y: f64, width: f64, height: f64) Vec3 {
    var p = axes.eye;
    const ux = (x - 0.5 * width) / height;
    const uy = (y - 0.5 * height) / height;
    var v = norm(axes.forward * splat(focal) + axes.right * splat(ux) - axes.up * splat(uy));
    const l = cross(p, v);
    const h2 = dot(l, l);
    var col = splat(0);
    var alpha: f64 = 0;
    var glow: f64 = 0;
    var escaped = false;
    for (0..360) |_| {
        const r2 = dot(p, p);
        const r = @sqrt(r2);
        if (r < 1) break;
        var dt = std.math.clamp(0.06 * r, 0.015, 1.5);
        // Near the disk's plane, smaller steps find its edge sharp.
        if (@abs(p[1]) < 0.6 and r < disk_out + 1) dt = @min(dt, @max(0.05, @abs(p[1])));
        v += p * splat(-1.5 * h2 / (r2 * r2 * r) * dt);
        const np = p + v * splat(dt);
        if (p[1] * np[1] <= 0 and p[1] != np[1]) {
            const hit = mix(p, np, p[1] / (p[1] - np[1]));
            const e = disk(shot.time, hit, norm(v));
            const a = std.math.clamp(e[3], 0, 1);
            col += v3(e[0], e[1], e[2]) * splat((1 - alpha) * a);
            alpha += (1 - alpha) * a * 0.92;
        }
        // Light circling near the photon sphere, a faint halo.
        const ring = r - 1.5;
        glow += @exp(-ring * ring * 6) * dt;
        p = np;
        if (r > escape and dot(p, v) > 0) {
            escaped = true;
            break;
        }
        if (alpha > 0.995) break;
    }
    // A ray still circling when its steps run out is as good as caught.
    if (escaped) {
        col += sky(norm(v)) * splat(1 - alpha);
        col += v3(1, 0.62, 0.32) * splat(glow * 0.03 * (1 - alpha));
    }
    const mapped = aces(col * splat(1.1));
    return .{ std.math.pow(f64, mapped[0], 1.0 / 2.2), std.math.pow(f64, mapped[1], 1.0 / 2.2), std.math.pow(f64, mapped[2], 1.0 / 2.2) };
}

/// A picture of colors from 0 to 1, three floats a pixel.
const Plane = struct {
    data: []f32 = &.{},
    width: usize = 0,
    height: usize = 0,

    fn resize(self: *Plane, allocator: std.mem.Allocator, width: usize, height: usize) !void {
        if (self.width == width and self.height == height) return;
        self.data = try allocator.realloc(self.data, width * height * 3);
        self.width = width;
        self.height = height;
    }

    fn set(self: *Plane, x: usize, y: usize, c: Vec3) void {
        const i = (y * self.width + x) * 3;
        self.data[i] = @floatCast(c[0]);
        self.data[i + 1] = @floatCast(c[1]);
        self.data[i + 2] = @floatCast(c[2]);
    }

    fn texel(self: *const Plane, x: isize, y: isize) Vec3 {
        const cx: usize = @intCast(std.math.clamp(x, 0, @as(isize, @intCast(self.width)) - 1));
        const cy: usize = @intCast(std.math.clamp(y, 0, @as(isize, @intCast(self.height)) - 1));
        const i = (cy * self.width + cx) * 3;
        return .{ self.data[i], self.data[i + 1], self.data[i + 2] };
    }

    /// The color at (x, y) in pixels, blended between the four nearest.
    fn sample(self: *const Plane, x: f64, y: f64) Vec3 {
        const fx = x - 0.5;
        const fy = y - 0.5;
        const x0 = @floor(fx);
        const y0 = @floor(fy);
        const kx = fx - x0;
        const ky = fy - y0;
        const ix: isize = @intFromFloat(x0);
        const iy: isize = @intFromFloat(y0);
        return mix(mix(self.texel(ix, iy), self.texel(ix + 1, iy), kx), mix(self.texel(ix, iy + 1), self.texel(ix + 1, iy + 1), kx), ky);
    }
};

/// The glow of the brightest light at (x, y) of the glow's picture: the
/// scene sampled around it where it is brighter than a threshold, weighted
/// toward the middle.
fn bloom(scene: *const Plane, glow: *const Plane, x: f64, y: f64) Vec3 {
    const sw: f64 = @floatFromInt(scene.width);
    const sh: f64 = @floatFromInt(scene.height);
    const ax = x / @as(f64, @floatFromInt(glow.width)) * sw;
    const ay = y / @as(f64, @floatFromInt(glow.height)) * sh;
    const radius = sh * 0.018;
    var sum = splat(0);
    var weight: f64 = 0;
    for (0..32) |i| {
        const f: f64 = @floatFromInt(i);
        const r = @sqrt((f + 0.5) / 32);
        const a = f * 2.39996;
        const w = @exp(-r * r * 2.5);
        const c = scene.sample(ax + radius * r * @cos(a), ay + radius * r * @sin(a));
        const bright = @max(c - splat(0.5), splat(0)) / splat(0.5);
        sum += bright * bright * splat(w);
        weight += w;
    }
    return sum / splat(weight);
}

fn hash12(x: f64, y: f64) f64 {
    var p3 = v3(x, y, x) * splat(0.1031);
    p3 -= @floor(p3);
    p3 += splat(dot(p3, v3(p3[1], p3[2], p3[0]) + splat(33.33)));
    const k = (p3[0] + p3[1]) * p3[2];
    return k - @floor(k);
}

/// The finish at (x, y): the scene, its colors parted a little toward the
/// edges as a lens parts them, the glow spread wide over it, darker corners
/// and a film's grain.
fn finish(scene: *const Plane, glow: *const Plane, time: f64, x: f64, y: f64) Vec3 {
    const sw: f64 = @floatFromInt(scene.width);
    const sh: f64 = @floatFromInt(scene.height);
    const u = x / sw;
    const v = y / sh;
    const cx = u - 0.5;
    const cy = v - 0.5;
    const split = (cx * cx + cy * cy) * 0.018;
    var col = v3(
        scene.sample((u - cx * split) * sw, (v - cy * split) * sh)[0],
        scene.sample(u * sw, v * sh)[1],
        scene.sample((u + cx * split) * sw, (v + cy * split) * sh)[2],
    );
    const ax = u * @as(f64, @floatFromInt(glow.width));
    const ay = v * @as(f64, @floatFromInt(glow.height));
    var light = glow.sample(ax, ay) * splat(0.4);
    for (0..12) |i| {
        const f: f64 = @floatFromInt(i);
        const a = f * 2.39996;
        const r = 1.5 + f * 0.7;
        light += glow.sample(ax + r * @cos(a), ay + r * @sin(a)) * splat(0.1 * @exp(-f * 0.12));
    }
    col = splat(1) - (splat(1) - col) * (splat(1) - @min(light * splat(1.1), splat(1)));
    col *= splat(0.25 + 0.75 * std.math.pow(f64, 16 * u * v * (1 - u) * (1 - v), 0.22));
    col += splat((hash12(x + (time - @floor(time)) * 131, y + (time - @floor(time)) * 131) - 0.5) / 96);
    return @max(splat(0), @min(splat(1), col));
}

/// Draws frames on a thread of its own, with helpers sharing the rows, and
/// hands each to the window's thread when it is done.
const Renderer = struct {
    allocator: std.mem.Allocator,
    /// Threads that share the rows with the drawing thread.
    helpers: usize = 0,
    thread: ?std.Thread = null,
    mutex: zio.Mutex = .{},
    wake: zio.Condition = .{},
    /// The frame asked for, and its size in pixels; quit ends the thread.
    pending: ?Shot = null,
    width: usize = 0,
    height: usize = 0,
    quit: bool = false,
    /// Called on the drawing thread when a frame is done.
    done: ?*const fn (*Renderer) void = null,
    scene: Plane = .{},
    glow: Plane = .{},
    /// The finished frame, premultiplied BGRA, and how long it took in
    /// seconds.
    out: []u8 = &.{},
    took: f64 = 0,

    fn start(self: *Renderer) !void {
        const helpers = @max(1, (std.Thread.getCpuCount() catch 2) -| 1);
        self.helpers = helpers;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn stop(self: *Renderer) void {
        if (self.thread) |thread| {
            self.mutex.lock();
            self.quit = true;
            self.wake.signal();
            self.mutex.unlock();
            thread.join();
            self.thread = null;
        }
        self.allocator.free(self.scene.data);
        self.allocator.free(self.glow.data);
        self.allocator.free(self.out);
    }

    /// Asks for a frame of `width` by `height` pixels; the last frame must
    /// be done.
    fn ask(self: *Renderer, shot: Shot, width: usize, height: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending = shot;
        self.width = width;
        self.height = height;
        self.wake.signal();
    }

    fn run(self: *Renderer) void {
        while (true) {
            self.mutex.lock();
            while (self.pending == null and !self.quit) self.wake.wait(&self.mutex);
            if (self.quit) return self.mutex.unlock();
            const shot = self.pending.?;
            self.pending = null;
            const width = self.width;
            const height = self.height;
            self.mutex.unlock();
            const began = zio.nanoTimestamp();
            self.draw(shot, width, height, true) catch |err| std.log.err("blackhole: {s}", .{@errorName(err)});
            self.took = @as(f64, @floatFromInt(zio.nanoTimestamp() - began)) / std.time.ns_per_s;
            if (self.done) |done| done(self);
        }
    }

    /// Draws the frame into `out`, sharing the rows with the helpers when
    /// `parallel`.
    fn draw(self: *Renderer, shot: Shot, width: usize, height: usize, parallel: bool) !void {
        try self.scene.resize(self.allocator, width, height);
        try self.glow.resize(self.allocator, @max(1, width / glow_scale), @max(1, height / glow_scale));
        if (self.out.len != width * height * 4) self.out = try self.allocator.realloc(self.out, width * height * 4);
        inline for (.{ Pass.scene, Pass.glow, Pass.finish }) |pass| {
            const rows = switch (pass) {
                .glow => self.glow.height,
                else => height,
            };
            if (parallel) {
                var group: std.Io.Group = .init;
                const bands = 4 * (self.helpers + 1);
                for (0..bands) |band| group.async(zio.io(), rowsOf, .{ self, pass, shot, band, bands, rows });
                group.await(zio.io()) catch unreachable;
            } else rowsOf(self, pass, shot, 0, 1, rows);
        }
    }

    const Pass = enum { scene, glow, finish };

    /// Draws every `bands`th row of a pass, from `band`.
    fn rowsOf(self: *Renderer, pass: Pass, shot: Shot, band: usize, bands: usize, rows: usize) void {
        const axes = shot.camera.axes();
        var y = band;
        while (y < rows) : (y += bands) {
            const fy = @as(f64, @floatFromInt(y)) + 0.5;
            switch (pass) {
                .scene => for (0..self.scene.width) |x| self.scene.set(x, y, trace(shot, axes, @as(f64, @floatFromInt(x)) + 0.5, fy, @floatFromInt(self.scene.width), @floatFromInt(self.scene.height))),
                .glow => for (0..self.glow.width) |x| self.glow.set(x, y, bloom(&self.scene, &self.glow, @as(f64, @floatFromInt(x)) + 0.5, fy)),
                .finish => for (0..self.scene.width) |x| {
                    const c = finish(&self.scene, &self.glow, shot.time, @as(f64, @floatFromInt(x)) + 0.5, fy);
                    const i = (y * self.scene.width + x) * 4;
                    self.out[i] = @intFromFloat(@round(c[2] * 255));
                    self.out[i + 1] = @intFromFloat(@round(c[1] * 255));
                    self.out[i + 2] = @intFromFloat(@round(c[0] * 255));
                    self.out[i + 3] = 255;
                },
            }
        }
    }
};

const Hole = struct {
    allocator: std.mem.Allocator,
    camera: Camera = .{ .yaw = 0.6, .pitch = 0.1, .dist = rest, .spin_yaw = orbit_speed },
    /// The disk's clock, which stands still while the desktop asks for less
    /// motion; last is the frame's time.
    time: f64 = 0,
    last: ?u64 = null,
    /// The pointer's drag: whether the primary button is down, where it
    /// last was and when (nanoseconds); touched tells that the user moved
    /// the camera, and the hint fades.
    down: bool = false,
    last_x: f32 = 0,
    last_y: f32 = 0,
    last_move: i128 = 0,
    touched: bool = false,
    hint: f64 = 1,
    /// The scene's resolution, a fraction of the window's pixels across;
    /// how long frames take to draw, smoothed, and how long they took longer
    /// or shorter than they should.
    quality: f64 = 0.25,
    frame: f64 = 1.0 / 60.0,
    slow: f64 = 0,
    fast: f64 = 0,
    reduce: bool = false,

    renderer: Renderer,
    host: ?*view.Host = null,
    image: ?ui.PixelImage = null,
    /// A frame is being drawn; the shot the image shows.
    busy: bool = false,
    shown: ?Shot = null,
    /// The window's size in DIPs and its pixels per DIP.
    width: f32 = 1200,
    height: f32 = 760,
    scale: f32 = 1,

    fn init(allocator: std.mem.Allocator) Hole {
        return .{ .allocator = allocator, .renderer = .{ .allocator = allocator } };
    }

    fn deinit(self: *Hole) void {
        self.renderer.stop();
        if (self.image) |*image| image.deinit();
    }

    fn build(self: *Hole, v: *view.View) anyerror!void {
        self.reduce = v.preferences.reduce_motion;
        const now = v.time();
        if (self.last) |last| self.step(@min(@as(f64, @floatFromInt(now -| last)) / std.time.ns_per_s, 0.1));
        self.last = now;
        if (self.moving()) v.wakeAt(now + std.time.ns_per_s / 60);

        try v.column(.{ .grow = 1, .self_align = .stretch, .background = 0x000000 });
        // The picture fills the window behind the words; the leaf takes the
        // pointer everywhere above them.
        try v.embed(.{ .context = self, .measure = measure, .paint = paint, .input = input }, .{ .key = 1, .grow = 1, .self_align = .stretch, .name = "Black hole" });
        try v.row(.{ .self_align = .stretch, .alignment = .end, .padding = .{ .left = 30, .right = 28, .bottom = 26 } });
        try v.column(.{ .gap = 4 });
        try v.text("Gargantua", .{ .font = .{ .size = 22, .weight = .semibold }, .color = white });
        try v.text("A black hole, its light traced through gravity on the CPU", .{ .font = .{ .size = 12 }, .color = muted, .min_width = 380 });
        try v.end();
        try v.spacer(.{});
        // The hint fades into the dark around it.
        const grey: u32 = @intFromFloat(@round(0x80 * self.hint));
        if (self.hint > 0) try v.text("Drag to orbit · Scroll to zoom", .{ .font = .{ .size = 12 }, .color = grey << 16 | grey << 8 | grey, .min_width = 200 });
        try v.end();
        try v.end();
    }

    /// Whether anything moves on its own.
    fn moving(self: *const Hole) bool {
        return !self.reduce or self.down or self.camera.spinning() or (self.touched and self.hint > 0);
    }

    /// Moves the scene on by dt seconds: the camera orbits, a throw slows
    /// down, and the hint fades once the user moved the camera.
    fn step(self: *Hole, dt: f64) void {
        if (!self.reduce) self.time += dt;
        const cam = &self.camera;
        if (!self.down) {
            const goal: f64 = if (self.reduce) 0 else orbit_speed;
            const k = 1 - @exp(-dt * settle);
            cam.spin_yaw += (goal - cam.spin_yaw) * k;
            cam.spin_pitch -= cam.spin_pitch * @min(1, 2 * k);
            cam.yaw += cam.spin_yaw * dt;
            cam.pitch = std.math.clamp(cam.pitch + cam.spin_pitch * dt, -max_pitch, max_pitch);
        }
        if (self.touched) self.hint = @max(0, self.hint - dt / 0.6);
    }

    /// Fits the resolution to how long the last frame took to draw.
    fn fit(self: *Hole, took: f64) void {
        if (took <= 0) return;
        self.frame += (took - self.frame) * 0.1;
        self.slow = if (self.frame > slow_frame) self.slow + took else 0;
        self.fast = if (self.frame < fast_frame) self.fast + took else 0;
        if (self.slow > 0.5 and self.quality > min_quality) {
            self.quality = @max(min_quality, self.quality - quality_step);
            self.slow = 0;
            self.frame = fast_frame;
        } else if (self.fast > 3 and self.quality < max_quality) {
            self.quality = @min(max_quality, self.quality + quality_step);
            self.fast = 0;
        }
    }

    fn press(self: *Hole, x: f32, y: f32, now: i128) void {
        self.down = true;
        self.touched = true;
        self.last_x = x;
        self.last_y = y;
        self.last_move = now;
        self.camera.spin_yaw = 0;
        self.camera.spin_pitch = 0;
    }

    /// A drag turns the camera around the hole, and its speed, smoothed
    /// over the last moves, is the throw.
    fn drag(self: *Hole, x: f32, y: f32, now: i128) void {
        const cam = &self.camera;
        const dt = @max(@as(f64, @floatFromInt(now - self.last_move)) / std.time.ns_per_s, 1.0 / 240.0);
        const dyaw = -@as(f64, x - self.last_x) * 0.005;
        const dpitch = @as(f64, y - self.last_y) * 0.004;
        cam.yaw += dyaw;
        cam.pitch = std.math.clamp(cam.pitch + dpitch, -max_pitch, max_pitch);
        const k = @min(1, dt / 0.06);
        cam.spin_yaw += (dyaw / dt - cam.spin_yaw) * k;
        cam.spin_pitch += (dpitch / dt - cam.spin_pitch) * k;
        self.last_x = x;
        self.last_y = y;
        self.last_move = now;
    }

    fn release(self: *Hole, now: i128) void {
        self.down = false;
        // Held still before letting go: no throw.
        if (now - self.last_move > 80 * std.time.ns_per_ms) {
            self.camera.spin_yaw = 0;
            self.camera.spin_pitch = 0;
        }
    }

    fn zoom(self: *Hole, dy: f32) void {
        self.touched = true;
        self.camera.dist = std.math.clamp(self.camera.dist * @exp(@as(f64, dy) * 0.003), near, far);
    }

    fn measure(_: *anyopaque, _: ui.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 0, .height = 0 }, .preferred = .{ .width = 0, .height = 0 } };
    }

    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *Hole = @ptrCast(@alignCast(ptr));
        const now = zio.nanoTimestamp();
        switch (event) {
            .pointer_down => |p| self.press(p.position.x, p.position.y, now),
            .pointer_drag => |p| self.drag(p.position.x, p.position.y, now),
            .pointer_up => self.release(now),
            .pointer_cancel => self.release(now),
            .wheel => |w| self.zoom(w.delta.y),
            else => return false,
        }
        if (self.host) |host| if (host.context.window) |window| window.invalidate();
        return true;
    }

    fn paint(ptr: *anyopaque, frame: *ui.Frame, _: u64, _: view.Rect) anyerror!void {
        const self: *Hole = @ptrCast(@alignCast(ptr));
        self.scale = frame.size.scale;
        self.width = @as(f32, @floatFromInt(frame.size.width)) / frame.size.scale;
        self.height = @as(f32, @floatFromInt(frame.size.height)) / frame.size.scale;
        if (self.image) |*image| if (image.view()) |picture| try frame.image(.{ .x = 0, .y = 0, .width = self.width, .height = self.height }, picture, .{});
        self.ask();
    }

    /// The size of the next frame, in pixels.
    fn pixels(self: *const Hole) [2]usize {
        const k = @as(f64, self.scale) * self.quality;
        return .{ @intFromFloat(@max(1, @round(self.width * k))), @intFromFloat(@max(1, @round(self.height * k))) };
    }

    /// Asks for the next frame unless one is being drawn or the picture
    /// already shows it.
    fn ask(self: *Hole) void {
        if (self.busy or self.renderer.thread == null) return;
        const shot: Shot = .{ .time = self.time, .camera = self.camera };
        const size = self.pixels();
        if (self.shown) |shown| if (std.meta.eql(shown, shot) and self.image != null and self.image.?.width == size[0] and self.image.?.height == size[1]) return;
        self.busy = true;
        self.shown = shot;
        self.renderer.ask(shot, size[0], size[1]);
    }

    /// On the drawing thread: the frame is done.
    fn drawn(renderer: *Renderer) void {
        const self: *Hole = @alignCast(@fieldParentPtr("renderer", renderer));
        const host = self.host orelse return;
        const window = host.context.window orelse return;
        window.app.post(.{ .context = self, .call = show }) catch {};
    }

    /// Shows the frame just drawn, and fits the resolution to it.
    fn show(ptr: *anyopaque) void {
        const self: *Hole = @ptrCast(@alignCast(ptr));
        self.busy = false;
        const host = self.host orelse return;
        const window = host.context.window orelse return;
        const renderer = &self.renderer;
        self.fit(renderer.took);
        const width: u32 = @intCast(renderer.scene.width);
        const height: u32 = @intCast(renderer.scene.height);
        if (self.image) |*image| if (image.width != width or image.height != height) {
            image.release(&host.context);
            image.deinit();
            self.image = null;
        };
        if (self.image == null) self.image = ui.PixelImage.init(self.allocator, width, height) catch return;
        const image = &self.image.?;
        @memcpy(image.pixels(), renderer.out);
        image.commit(&host.context) catch |err| std.log.err("blackhole: {s}", .{@errorName(err)});
        window.invalidate();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var hole: Hole = .init(allocator);
    defer hole.deinit();
    var storage: view.Storage(64, 2048) = .{};
    var host = view.Host.init(&hole, Hole.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0) }, .background = 0x000000 });
    hole.host = &host;
    var timer = view_timer.Timer.init(&host);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Black Hole", .width = 1200, .height = 760 });
    try host.attach(window);
    try timer.attach(app, allocator);
    hole.renderer.done = Hole.drawn;
    try hole.renderer.start();

    window.show();
    try app.run();
    hole.renderer.stop();
    hole.renderer = .{ .allocator = allocator };
    try timer.close();
    hole.host = null;
}

test "a drag orbits the camera, a throw keeps it turning, a scroll comes closer and the hint fades" {
    var hole: Hole = .init(std.testing.allocator);
    defer hole.deinit();
    var storage: view.Storage(64, 2048) = .{};
    var h = view.Harness.init(&hole, Hole.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 1200, .height = 760 }, .options = .{ .root = .{ .padding = view.Insets.all(0) } } });
    try h.render();
    _ = try h.find(.{ .text = "Drag to orbit · Scroll to zoom" });
    const yaw = hole.camera.yaw;
    const pitch = hole.camera.pitch;
    const ms = std.time.ns_per_ms;
    hole.press(500, 300, 0);
    hole.drag(560, 330, 16 * ms);
    hole.drag(620, 360, 32 * ms);
    hole.release(40 * ms);
    try std.testing.expectApproxEqAbs(yaw - 120 * 0.005, hole.camera.yaw, 0.05);
    try std.testing.expect(hole.camera.pitch > pitch);
    // Thrown, it turns on, slowing to its own orbit.
    try std.testing.expect(hole.camera.spin_yaw < -1);
    for (0..10) |_| hole.step(0.1);
    try std.testing.expectEqual(@as(f64, 0), hole.hint);
    try h.render();
    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Drag to orbit · Scroll to zoom" }));
    for (0..100) |_| hole.step(0.1);
    try std.testing.expectApproxEqAbs(orbit_speed, hole.camera.spin_yaw, 0.01);
    // Held still before letting go: no throw.
    hole.press(500, 300, 0);
    hole.drag(560, 300, 16 * ms);
    hole.release(200 * ms);
    try std.testing.expectEqual(@as(f64, 0), hole.camera.spin_yaw);
    for (0..40) |_| hole.zoom(-200);
    try std.testing.expectEqual(near, hole.camera.dist);
}

test "the camera looks at the hole, its axes a right-handed frame" {
    const camera: Camera = .{ .yaw = 0.7, .pitch = 0.3, .dist = 20 };
    const axes = camera.axes();
    try std.testing.expectApproxEqAbs(@as(f64, 20), @sqrt(dot(axes.eye, axes.eye)), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -1), dot(axes.forward, norm(axes.eye)), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), dot(axes.right, axes.up), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), dot(axes.right, axes.forward), 1e-9);
    try std.testing.expect(axes.up[1] > 0);
}

test "the resolution drops while frames take long and rises once they keep up" {
    var hole: Hole = .init(std.testing.allocator);
    defer hole.deinit();
    for (0..600) |_| hole.fit(1.0 / 20.0);
    try std.testing.expectEqual(min_quality, hole.quality);
    for (0..3000) |_| hole.fit(1.0 / 120.0);
    try std.testing.expectEqual(max_quality, hole.quality);
}

test "the hole's shadow is black, the disk bright and the sky dark" {
    var renderer: Renderer = .{ .allocator = std.testing.allocator };
    defer renderer.stop();
    const shot: Shot = .{ .time = 0, .camera = .{ .yaw = 0.6, .pitch = 0.1, .dist = rest } };
    try renderer.draw(shot, 48, 30, false);
    const at = struct {
        fn luma(r: *const Renderer, x: usize, y: usize) f64 {
            const i = (y * r.scene.width + x) * 3;
            return (r.scene.data[i] + r.scene.data[i + 1] + r.scene.data[i + 2]) / 3;
        }
    }.luma;
    // The middle looks into the hole, just past it the disk crosses, and
    // the corners see the sky.
    try std.testing.expect(at(&renderer, 24, 15) < 0.02);
    var brightest: f64 = 0;
    for (0..48) |x| brightest = @max(brightest, at(&renderer, x, 15));
    try std.testing.expect(brightest > 0.5);
    try std.testing.expect(at(&renderer, 0, 0) < 0.3);
    // The finish is opaque.
    try std.testing.expectEqual(@as(u8, 255), renderer.out[3]);
}
