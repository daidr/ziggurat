//! A little survivor game. Tomori, lost, holds out on a street at night
//! against stage fright (static, crows and shadows) for as long as she can.
//! She sings on her own, at the nearest of it; the player walks her and
//! picks up the stones it leaves, which she collects, and at each level
//! chooses one of three upgrades. Four bring a bandmate, who joins, follows
//! her and plays their part of the music: Anon on guitar, Soyo on bass,
//! Rāna on lead and Taki on drums.
//!
//! `ziggurat_game` runs it in fixed steps, and its camera follows Tomori,
//! shaking when she is hit. Everything it draws and plays is made by its
//! code: pixel art in a sheet drawn pixel by pixel, the world blitted from
//! it into a `ui.PixelImage` at the art's own resolution and shown on
//! whole screen pixels, and sounds and an original lo-fi tune synthesized
//! for `ziggurat_audio`.
//!
//! Arrows or WASD walk, Esc pauses and M plays or stops the music; at a
//! level, 1 2 3, a click, or the arrows and Space choose. With a gamepad:
//! the left stick or the d-pad walks, A chooses, Start pauses.
//!
//! Run it with `zig build run-mayoi`.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");
const game = @import("ziggurat_game");
const audio = @import("ziggurat_audio");
const text_layout = @import("ziggurat_text_layout");
const gamepad = game.gamepad;
const drawing = ui.drawing;

/// The world's fixed step, as game.View runs it.
const step_time = 1.0 / @as(f64, game.rate);

// The world.

/// A point or a direction in the world, in pixels of the art.
const Vec = struct {
    x: f64 = 0,
    y: f64 = 0,

    fn add(a: Vec, b: Vec) Vec {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    fn sub(a: Vec, b: Vec) Vec {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    fn mul(a: Vec, k: f64) Vec {
        return .{ .x = a.x * k, .y = a.y * k };
    }
    fn len(a: Vec) f64 {
        return std.math.hypot(a.x, a.y);
    }
    fn lerp(a: Vec, b: Vec, t: f64) Vec {
        return a.add(b.sub(a).mul(t));
    }
    /// `a` with a length of 1, or nothing for nothing.
    fn norm(a: Vec) Vec {
        const l = a.len();
        return if (l > 0) a.mul(1 / l) else .{};
    }
};

/// The kinds of stage fright, which come as time goes on: static, the noise
/// in her head; crows, the whispers; shadows, the doubts.
const Kind = enum { static, crow, shadow };

const KindInfo = struct { hp: f64, speed: f64, radius: f64, stones: u32 };
const kinds = std.EnumArray(Kind, KindInfo).init(.{
    .static = .{ .hp = 2, .speed = 22, .radius = 6, .stones = 1 },
    .crow = .{ .hp = 1, .speed = 46, .radius = 5, .stones = 2 },
    .shadow = .{ .hp = 7, .speed = 30, .radius = 6, .stones = 5 },
});

fn info(k: Kind) KindInfo {
    return kinds.get(k);
}

const Enemy = struct {
    id: u32,
    kind: Kind,
    pos: Vec,
    prev: Vec,
    hp: f64,
    /// Knockback, which fades.
    knock: Vec = .{},
    /// Seconds left of the flash of a hit, and before the picks hit it
    /// again.
    flash: f64 = 0,
    pick_hit: f64 = 0,
    /// Its animation's phase, and a crow's weaving.
    phase: f64,
    dead: bool = false,
};

/// What the vocalist sings at the noise.
const Note = struct {
    pos: Vec,
    prev: Vec,
    vel: Vec,
    damage: f64,
    /// Enemies it goes through.
    pierce: i32,
    life: f64,
    hit: [8]u32 = undefined,
    hits: usize = 0,

    fn struck(self: *const Note, id: u32) bool {
        return std.mem.indexOfScalar(u32, self.hit[0..self.hits], id) != null;
    }
};

/// What the fallen leave: the vocalist collects them.
const Stone = struct { pos: Vec, prev: Vec, value: u32, pulled: bool = false };

/// The cloud an enemy leaves, and a number of damage.
const Puff = struct { pos: Vec, t: f64 = 0 };
const Popup = struct {
    pos: Vec,
    t: f64 = 0,
    text: [8]u8 = undefined,
    len: usize = 0,

    fn label(self: *const Popup) []const u8 {
        return self.text[0..self.len];
    }
};

/// The upgrades a level offers, three at a time. Four bring a bandmate: the
/// first time, they join, and follow Tomori from then on.
const Upgrade = enum { voice, tempo, harmony, bass, picks, drums, shoes, eye, bandaid };
const upgrade_count = zio.fields(Upgrade).len;

const UpgradeInfo = struct { name: []const u8, desc: []const u8, max: u32, icon: usize, member: ?usize };
const upgrades = std.EnumArray(Upgrade, UpgradeInfo).init(.{
    .voice = .{ .name = "Louder", .desc = "Her notes hit harder", .max = 5, .icon = c_mic, .member = null },
    .tempo = .{ .name = "Tempo up", .desc = "She sings faster", .max = 5, .icon = c_metronome, .member = null },
    .harmony = .{ .name = "Harmony", .desc = "Anon joins on guitar:\none more note a volley", .max = 3, .icon = c_guitar, .member = guitarist },
    .bass = .{ .name = "Bassline", .desc = "Soyo joins on bass:\nnotes go through one more", .max = 3, .icon = c_bass_icon, .member = bassist },
    .picks = .{ .name = "Guitar picks", .desc = "Rāna joins on lead:\na pick circles you", .max = 5, .icon = c_pick, .member = lead },
    .drums = .{ .name = "Drum beat", .desc = "Taki joins on drums:\na beat blasts around you", .max = 4, .icon = c_drum, .member = drummer },
    .shoes = .{ .name = "Running shoes", .desc = "Walk faster", .max = 4, .icon = c_shoe, .member = null },
    .eye = .{ .name = "An eye for stones", .desc = "Stones come from\nfarther away", .max = 3, .icon = c_stone_icon, .member = null },
    .bandaid = .{ .name = "Band-aid", .desc = "One more band-aid,\nand heal two", .max = 5, .icon = c_bandaid, .member = null },
});

/// The band: Tomori sings, Anon plays guitar, Soyo the bass, Rāna lead
/// guitar and Taki the drums.
const vocalist = 0;
const guitarist = 1;
const bassist = 2;
const lead = 3;
const drummer = 4;
const member_count = 5;
const member_names = [member_count][]const u8{ "Tomori", "Anon", "Soyo", "Rāna", "Taki" };

/// The state of a game: before it, playing, choosing an upgrade, or over.
const State = enum { title, playing, choosing, over };

/// What happened in a step, for its sounds.
const Event = enum { sing, hit, kill, stone, level, hurt, beat, choose, join, over };

const max_enemies = 400;
/// The size of the grid's cells that find enemies near a point.
const grid_cell = 16;
/// Steps of the vocalist's trail the band follows, and steps between
/// bandmates on it.
const trail_len = 128;
const trail_gap = 12;

/// The game's state, advanced in fixed steps of simulated time.
const World = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    state: State = .title,
    /// Held out, in seconds.
    time: f64 = 0,

    /// The vocalist, by the middle of her feet, and where the player
    /// steers, at most 1 long.
    pos: Vec = .{},
    prev: Vec = .{},
    move: Vec = .{},
    facing_left: bool = false,
    walked: f64 = 0,
    hp: i32 = 5,
    max_hp: i32 = 5,
    /// Seconds left unhurtable.
    hurt: f64 = 0,
    speed: f64 = 62,
    /// How far stones come from.
    reach: f64 = 30,

    damage: f64 = 1,
    cooldown: f64 = 0.75,
    notes: i32 = 1,
    pierce: i32 = 0,
    levels: std.EnumArray(Upgrade, u32) = .initFill(0),

    /// The band in the order they joined, after the vocalist, and the trail
    /// they walk on.
    band: [member_count - 1]usize = undefined,
    band_len: usize = 0,
    trail: [trail_len]Vec = @splat(.{}),
    head: usize = 0,

    enemies: std.ArrayList(Enemy) = .empty,
    sung: std.ArrayList(Note) = .empty,
    stones: std.ArrayList(Stone) = .empty,
    puffs: std.ArrayList(Puff) = .empty,
    popups: std.ArrayList(Popup) = .empty,
    next_id: u32 = 0,

    spawn_timer: f64 = 0.5,
    sing_timer: f64 = 0,
    beat_timer: f64 = 1,
    wave_timer: f64 = 45,
    pick_angle: f64 = 0,
    beat_flash: f64 = 0,
    shake: f64 = 0,
    over_time: f64 = 0,

    xp: u32 = 0,
    level: u32 = 1,
    xp_next: u32 = 5,
    /// Stones collected, and enemies calmed.
    collected: u32 = 0,
    calmed: u32 = 0,
    choices: [3]Upgrade = undefined,
    choices_len: usize = 0,
    /// Who joined, shown for a while.
    banner: [40]u8 = undefined,
    banner_len: usize = 0,
    banner_time: f64 = 0,

    /// Half the view's size in the world: enemies come from beyond it.
    view: Vec = .{ .x = 180, .y = 110 },
    events: std.ArrayList(Event) = .empty,

    /// Enemies by cell, hashed.
    grid: [256]std.ArrayList(u32) = @splat(.empty),

    fn init(allocator: std.mem.Allocator, seed: u64) World {
        return .{ .allocator = allocator, .rng = .init(seed) };
    }

    fn deinit(self: *World) void {
        self.enemies.deinit(self.allocator);
        self.sung.deinit(self.allocator);
        self.stones.deinit(self.allocator);
        self.puffs.deinit(self.allocator);
        self.popups.deinit(self.allocator);
        self.events.deinit(self.allocator);
        for (&self.grid) |*list| list.deinit(self.allocator);
    }

    fn random(self: *World) std.Random {
        return self.rng.random();
    }

    /// Starts a game anew.
    fn reset(self: *World) void {
        const kept: World = self.*;
        self.* = .{ .allocator = kept.allocator, .rng = kept.rng, .view = kept.view, .enemies = kept.enemies, .sung = kept.sung, .stones = kept.stones, .puffs = kept.puffs, .popups = kept.popups, .events = kept.events, .grid = kept.grid };
        self.enemies.clearRetainingCapacity();
        self.sung.clearRetainingCapacity();
        self.stones.clearRetainingCapacity();
        self.puffs.clearRetainingCapacity();
        self.popups.clearRetainingCapacity();
        self.events.clearRetainingCapacity();
        self.state = .playing;
    }

    fn emit(self: *World, event: Event) void {
        self.events.append(self.allocator, event) catch {};
    }

    /// Advances the world by dt seconds.
    fn step(self: *World, dt: f64) void {
        if (self.state == .over) self.over_time += dt;
        if (self.state != .playing) return;
        self.time += dt;
        self.walk(dt);
        self.spawn(dt);
        self.chase(dt);
        self.sing(dt);
        self.fly(dt);
        self.spinPicks(dt);
        self.drum(dt);
        self.collect(dt);
        self.touch(dt);
        self.age(dt);
    }

    fn walk(self: *World, dt: f64) void {
        self.prev = self.pos;
        if (self.move.len() <= 0.05) return;
        self.pos = self.pos.add(self.move.mul(self.speed * dt));
        self.walked += self.move.len() * self.speed * dt;
        if (self.move.x < -0.1) self.facing_left = true else if (self.move.x > 0.1) self.facing_left = false;
        self.head = (self.head + 1) % trail_len;
        self.trail[self.head] = self.pos;
    }

    /// Where bandmate i of the band (0 the first to join) walks: on the
    /// vocalist's trail, a little behind the one before.
    fn follower(self: *const World, i: usize) Vec {
        return self.trail[(self.head + trail_len * 4 - (i + 1) * trail_gap) % trail_len];
    }

    /// Brings enemies from just beyond the view's edges, ever more and
    /// stronger, static in groups, and every 45 seconds a ring of it all
    /// around.
    fn spawn(self: *World, dt: f64) void {
        self.spawn_timer -= dt;
        while (self.spawn_timer <= 0) {
            self.spawn_timer += @max(0.08, 0.7 * std.math.pow(f64, 0.982, self.time));
            var k: Kind = .static;
            var n: usize = 1 + self.random().uintLessThan(usize, 1 + @as(usize, @intFromFloat(self.time / 40)));
            const r = self.random().float(f64);
            if (self.time > 60 and r < 0.15) {
                k = .shadow;
                n = 1;
            } else if (self.time > 25 and r < 0.4) {
                k = .crow;
                n = 1 + self.random().uintLessThan(usize, 2);
            }
            const at = self.edge(14);
            for (0..n) |_| self.add(k, at.add(.{ .x = self.random().float(f64) * 16 - 8, .y = self.random().float(f64) * 16 - 8 }));
        }
        self.wave_timer -= dt;
        if (self.wave_timer <= 0) {
            self.wave_timer = 45;
            const n: usize = 24 + @as(usize, @intFromFloat(self.time / 15));
            for (0..n) |i| {
                const a = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)) * 2 * std.math.pi;
                self.add(.static, self.pos.add((Vec{ .x = @cos(a), .y = @sin(a) }).mul(self.view.len() + 4)));
            }
        }
    }

    /// A point `margin` beyond the view's edges, anywhere around.
    fn edge(self: *World, margin: f64) Vec {
        const hw = self.view.x + margin;
        const hh = self.view.y + margin;
        const d = self.random().float(f64) * 4 * (hw + hh);
        const p: Vec = if (d < 2 * hw) .{ .x = d - hw, .y = -hh } else if (d < 4 * hw) .{ .x = d - 3 * hw, .y = hh } else if (d < 4 * hw + 2 * hh) .{ .x = -hw, .y = d - 4 * hw - hh } else .{ .x = hw, .y = d - 4 * hw - 3 * hh };
        return self.pos.add(p);
    }

    fn add(self: *World, k: Kind, at: Vec) void {
        if (self.enemies.items.len >= max_enemies) return;
        self.next_id += 1;
        self.enemies.append(self.allocator, .{ .id = self.next_id, .kind = k, .pos = at, .prev = at, .hp = info(k).hp * (1 + self.time / 100), .phase = self.random().float(f64) * 10 }) catch {};
    }

    /// The hash of the grid's cell (x, y).
    fn cellOf(x: i64, y: i64) usize {
        const h = @as(u64, @bitCast(x *% 73856093 ^ y *% 19349663));
        return @intCast(@as(u32, @truncate(h)) % 256);
    }

    fn cellAt(p: Vec) [2]i64 {
        return .{ @intFromFloat(@floor(p.x / grid_cell)), @intFromFloat(@floor(p.y / grid_cell)) };
    }

    /// Files the enemies in the grid.
    fn index(self: *World) void {
        for (&self.grid) |*bucket| bucket.clearRetainingCapacity();
        for (self.enemies.items, 0..) |e, i| {
            const c = cellAt(e.pos);
            self.grid[cellOf(c[0], c[1])].append(self.allocator, @intCast(i)) catch {};
        }
    }

    /// The enemies that may be within a cell of a point.
    const Near = struct {
        world: *World,
        cells: [9]usize = undefined,
        count: usize = 0,
        at: usize = 0,
        in: usize = 0,

        fn next(self: *Near) ?*Enemy {
            while (self.at < self.count) {
                const bucket = self.world.grid[self.cells[self.at]].items;
                if (self.in < bucket.len) {
                    const i = bucket[self.in];
                    self.in += 1;
                    return &self.world.enemies.items[i];
                }
                self.at += 1;
                self.in = 0;
            }
            return null;
        }
    };

    fn near(self: *World, p: Vec) Near {
        var n: Near = .{ .world = self };
        const c = cellAt(p);
        var dy: i64 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i64 = -1;
            while (dx <= 1) : (dx += 1) {
                const h = cellOf(c[0] + dx, c[1] + dy);
                // Two cells may hash alike.
                if (std.mem.indexOfScalar(usize, n.cells[0..n.count], h) != null) continue;
                n.cells[n.count] = h;
                n.count += 1;
            }
        }
        return n;
    }

    /// Moves the enemies toward the vocalist, apart from each other.
    fn chase(self: *World, dt: f64) void {
        const far = self.view.len() * 3;
        for (self.enemies.items) |*e| {
            e.prev = e.pos;
            e.phase += dt;
            const to = self.pos.sub(e.pos);
            if (to.len() > far) {
                // Left behind: others come.
                e.dead = true;
                continue;
            }
            var dir = to.norm();
            if (e.kind == .crow) dir = dir.add((Vec{ .x = -dir.y, .y = dir.x }).mul(0.7 * @sin(e.phase * 5)));
            e.pos = e.pos.add(dir.mul(info(e.kind).speed * dt)).add(e.knock.mul(dt));
            e.knock = e.knock.mul(@exp(-9 * dt));
        }
        self.index();
        for (self.enemies.items) |*e| {
            var it = self.near(e.pos);
            while (it.next()) |o| {
                if (o == e) continue;
                var d = e.pos.sub(o.pos);
                const r = info(e.kind).radius + info(o.kind).radius;
                var l = d.len();
                if (l < r) {
                    if (l == 0) {
                        d = .{ .x = 1 };
                        l = 1;
                    }
                    e.pos = e.pos.add(d.mul((r - l) / l * 0.5));
                }
            }
        }
    }

    /// Sends notes at the nearest enemy in reach.
    fn sing(self: *World, dt: f64) void {
        self.sing_timer -= dt;
        if (self.sing_timer > 0) return;
        var target: ?*Enemy = null;
        var best: f64 = 200;
        for (self.enemies.items) |*e| {
            const d = e.pos.sub(self.pos).len();
            if (d < best and !e.dead) {
                target = e;
                best = d;
            }
        }
        const aimed = target orelse {
            self.sing_timer = 0;
            return;
        };
        self.sing_timer = self.cooldown;
        const from = self.pos.add(.{ .y = -8 });
        const aim = std.math.atan2(aimed.pos.y - from.y, aimed.pos.x - from.x);
        for (0..@intCast(self.notes)) |i| {
            const a = aim + (@as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(self.notes - 1)) / 2) * 0.22;
            self.sung.append(self.allocator, .{ .pos = from, .prev = from, .vel = (Vec{ .x = @cos(a), .y = @sin(a) }).mul(200), .damage = self.damage, .pierce = self.pierce, .life = 1.2 }) catch {};
        }
        self.emit(.sing);
    }

    fn fly(self: *World, dt: f64) void {
        for (self.sung.items) |*n| {
            n.prev = n.pos;
            n.pos = n.pos.add(n.vel.mul(dt));
            n.life -= dt;
            var it = self.near(n.pos);
            while (it.next()) |e| {
                if (n.life <= 0 or e.dead or n.struck(e.id) or e.pos.sub(n.pos).len() > info(e.kind).radius + 3) continue;
                if (n.hits < n.hit.len) {
                    n.hit[n.hits] = e.id;
                    n.hits += 1;
                }
                self.hurtEnemy(e, n.damage, n.pos.sub(n.vel));
                n.pierce -= 1;
                if (n.pierce < 0) n.life = 0;
            }
        }
        removeIf(Note, &self.sung, struct {
            fn gone(n: Note) bool {
                return n.life <= 0;
            }
        }.gone);
    }

    /// Where pick i of n is.
    fn pickPos(i: usize, n: u32, around: Vec, angle: f64) Vec {
        const a = angle + @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)) * 2 * std.math.pi;
        return around.add((Vec{ .x = @cos(a), .y = @sin(a) * 0.8 }).mul(30)).add(.{ .y = -6 });
    }

    fn spinPicks(self: *World, dt: f64) void {
        const n = self.levels.get(.picks);
        if (n == 0) return;
        self.pick_angle += 3.4 * dt;
        for (0..n) |i| {
            const at = pickPos(i, n, self.pos, self.pick_angle);
            var it = self.near(at);
            while (it.next()) |e| if (!e.dead and e.pick_hit <= 0 and e.pos.sub(at).len() < info(e.kind).radius + 6) {
                e.pick_hit = 0.4;
                self.hurtEnemy(e, 1 + @as(f64, @floatFromInt(n)) / 3, self.pos);
            };
        }
    }

    /// How far the drummer's beat reaches at its level.
    fn beatRadius(self: *const World) f64 {
        return 44 + 12 * @as(f64, @floatFromInt(self.levels.get(.drums)));
    }

    fn drum(self: *World, dt: f64) void {
        const lv = self.levels.get(.drums);
        if (lv == 0) return;
        self.beat_timer -= dt;
        if (self.beat_timer > 0) return;
        self.beat_timer = 4.6 - 0.6 * @as(f64, @floatFromInt(lv));
        self.beat_flash = 0.4;
        self.shake = @max(self.shake, 0.12);
        const r = self.beatRadius();
        for (self.enemies.items) |*e| if (!e.dead and e.pos.sub(self.pos).len() < r) {
            self.hurtEnemy(e, 1 + @as(f64, @floatFromInt(lv)), self.pos);
            e.knock = e.knock.mul(2);
        };
        self.emit(.beat);
    }

    /// Hurts e by d, knocking it away from where the hit came from.
    fn hurtEnemy(self: *World, e: *Enemy, d: f64, from: Vec) void {
        e.hp -= d;
        e.flash = 0.12;
        const push: f64 = if (e.kind == .shadow) 40 else 90;
        e.knock = e.pos.sub(from).norm().mul(push);
        var popup: Popup = .{ .pos = e.pos.add(.{ .y = -10 }) };
        popup.len = (std.fmt.bufPrint(&popup.text, "{d}", .{@round(d * 10) / 10}) catch @as([]const u8, "")).len;
        self.popups.append(self.allocator, popup) catch {};
        if (e.hp > 0) return self.emit(.hit);
        e.dead = true;
        self.calmed += 1;
        self.stones.append(self.allocator, .{ .pos = e.pos, .prev = e.pos, .value = info(e.kind).stones }) catch {};
        self.puffs.append(self.allocator, .{ .pos = e.pos }) catch {};
        self.emit(.kill);
    }

    /// Draws in the stones within reach, and levels up.
    fn collect(self: *World, dt: f64) void {
        for (self.stones.items) |*s| {
            s.prev = s.pos;
            const to = self.pos.add(.{ .y = -4 }).sub(s.pos);
            const d = to.len();
            if (d < self.reach) s.pulled = true;
            if (!s.pulled) continue;
            if (d < 5) {
                self.xp += s.value;
                self.collected += 1;
                s.value = 0;
                self.emit(.stone);
                continue;
            }
            s.pos = s.pos.add(to.norm().mul(@min(d, (90 + self.speed * 1.5) * dt)));
        }
        removeIf(Stone, &self.stones, struct {
            fn gone(s: Stone) bool {
                return s.value == 0;
            }
        }.gone);
        self.levelUp();
    }

    fn levelUp(self: *World) void {
        if (self.state != .playing or self.xp < self.xp_next) return;
        self.xp -= self.xp_next;
        self.level += 1;
        self.xp_next = 3 + self.level * 2;
        self.choices_len = 0;
        var open: [upgrade_count]Upgrade = undefined;
        var open_len: usize = 0;
        var joining: [upgrade_count]Upgrade = undefined;
        var joining_len: usize = 0;
        for (std.enums.values(Upgrade)) |u| {
            if (self.levels.get(u) >= upgrades.get(u).max) continue;
            if (upgrades.get(u).member != null and self.levels.get(u) == 0) {
                joining[joining_len] = u;
                joining_len += 1;
            } else {
                open[open_len] = u;
                open_len += 1;
            }
        }
        self.random().shuffle(Upgrade, open[0..open_len]);
        self.random().shuffle(Upgrade, joining[0..joining_len]);
        // A bandmate is always among the choices until all have joined.
        if (joining_len > 0) {
            self.choices[0] = joining[0];
            self.choices_len = 1;
            for (joining[1..joining_len]) |u| {
                open[open_len] = u;
                open_len += 1;
            }
            self.random().shuffle(Upgrade, open[0..open_len]);
        }
        for (open[0..@min(3 - self.choices_len, open_len)]) |u| {
            self.choices[self.choices_len] = u;
            self.choices_len += 1;
        }
        self.random().shuffle(Upgrade, self.choices[0..self.choices_len]);
        if (self.choices_len > 0) self.state = .choosing;
        self.emit(.level);
    }

    /// Takes the upgrade offered at i.
    fn choose(self: *World, i: usize) void {
        if (self.state != .choosing or i >= self.choices_len) return;
        const u = self.choices[i];
        self.levels.getPtr(u).* += 1;
        switch (u) {
            .voice => self.damage += 1,
            .tempo => self.cooldown *= 0.8,
            .harmony => self.notes += 1,
            .bass => self.pierce += 1,
            .shoes => self.speed *= 1.12,
            .eye => self.reach *= 1.45,
            .bandaid => {
                self.max_hp += 1;
                self.hp = @min(self.hp + 2, self.max_hp);
            },
            else => {},
        }
        self.state = .playing;
        if (upgrades.get(u).member) |m| if (self.levels.get(u) == 1) {
            self.band[self.band_len] = m;
            self.band_len += 1;
            self.banner_len = (std.fmt.bufPrint(&self.banner, "{s} joins the band!", .{member_names[m]}) catch @as([]const u8, "")).len;
            self.banner_time = 2.5;
            // They come from where the vocalist walked a moment ago.
            self.emit(.join);
            return self.levelUp();
        };
        self.emit(.choose);
        self.levelUp();
    }

    /// Whether bandmate m is in the band.
    fn joined(self: *const World, m: usize) bool {
        return std.mem.indexOfScalar(usize, self.band[0..self.band_len], m) != null;
    }

    /// Hurts the vocalist when an enemy reaches her.
    fn touch(self: *World, dt: f64) void {
        if (self.hurt > 0) {
            self.hurt -= dt;
            return;
        }
        var it = self.near(self.pos);
        while (it.next()) |e| {
            if (self.hurt > 0 or e.dead or e.pos.sub(self.pos).len() > info(e.kind).radius + 4) continue;
            self.hp -= 1;
            self.hurt = 1;
            self.shake = 0.3;
            self.emit(.hurt);
            for (self.enemies.items) |*o| if (o.pos.sub(self.pos).len() < 30) {
                o.knock = o.pos.sub(self.pos).norm().mul(160);
            };
            if (self.hp <= 0) {
                self.state = .over;
                self.emit(.over);
            }
        }
    }

    /// Moves on the effects, and forgets the dead.
    fn age(self: *World, dt: f64) void {
        for (self.enemies.items) |*e| {
            e.flash -= dt;
            e.pick_hit -= dt;
        }
        removeIf(Enemy, &self.enemies, struct {
            fn gone(e: Enemy) bool {
                return e.dead;
            }
        }.gone);
        for (self.puffs.items) |*p| p.t += dt;
        removeIf(Puff, &self.puffs, struct {
            fn gone(p: Puff) bool {
                return p.t > 0.32;
            }
        }.gone);
        for (self.popups.items) |*p| p.t += dt;
        removeIf(Popup, &self.popups, struct {
            fn gone(p: Popup) bool {
                return p.t > 0.6;
            }
        }.gone);
        self.shake = @max(self.shake - dt, 0);
        self.beat_flash = @max(self.beat_flash - dt, 0);
        self.banner_time = @max(self.banner_time - dt, 0);
    }
};

fn removeIf(comptime T: type, list: *std.ArrayList(T), comptime gone: fn (T) bool) void {
    var kept: usize = 0;
    for (list.items) |item| if (!gone(item)) {
        list.items[kept] = item;
        kept += 1;
    };
    list.shrinkRetainingCapacity(kept);
}

// The art: a sheet of 8×8 cells of 16 pixels, drawn here pixel by pixel so
// that the example needs no files.

const cell = 16;
const sheet_size = 8 * cell;

// Cells of the sheet.
const c_pave = 0;
const c_pave2 = 1;
const c_petals = 2;
const c_petals2 = 3;
const c_crack = 4;
const c_grate = 5;
/// Two frames for each bandmate, in the band's order.
const c_member = 8;
/// Two frames each.
const c_static = c_member + 2 * member_count;
const c_crow = c_static + 2;
const c_shadow = c_crow + 2;
const c_note = c_shadow + 2;
const c_pick = c_note + 1;
/// Three kinds, by value.
const c_stone = c_pick + 1;
const c_bandaid = c_stone + 3;
const c_bandaid_empty = c_bandaid + 1;
/// Three frames.
const c_puff = c_bandaid_empty + 1;
const c_mic = c_puff + 3;
const c_metronome = c_mic + 1;
const c_guitar = c_metronome + 1;
const c_bass_icon = c_guitar + 1;
const c_drum = c_bass_icon + 1;
const c_shoe = c_drum + 1;
const c_stone_icon = c_shoe + 1;

/// A color of the art, straight alpha: 0xAARRGGBB.
fn rgb(hex: u32) u32 {
    return 0xff000000 | hex;
}
const shadow_color: u32 = 0x50000000;

/// Colors for the characters of rows of pixel art; others are transparent.
const Palette = [128]u32;

fn palette(entries: anytype) Palette {
    var p: Palette = @splat(0);
    inline for (entries) |entry| p[entry[0]] = entry[1];
    return p;
}

/// The sheet's pixels.
const Sheet = struct {
    pixels: [sheet_size * sheet_size]u32 = @splat(0),

    /// One cell of the sheet to draw into.
    const Pen = struct {
        sheet: *Sheet,
        ox: usize,
        oy: usize,

        fn px(self: Pen, x: i64, y: i64, color: u32) void {
            if (x < 0 or y < 0 or x >= cell or y >= cell) return;
            self.sheet.pixels[(self.oy + @as(usize, @intCast(y))) * sheet_size + self.ox + @as(usize, @intCast(x))] = color;
        }

        /// Draws pixel art given as rows of characters, each a color of
        /// `pal`, from row `from`.
        fn rows(self: Pen, pal: *const Palette, from: usize, art: []const []const u8) void {
            for (art, from..) |row, y| for (row, 0..) |c, x| {
                if (c < 128 and pal[c] != 0) self.px(@intCast(x), @intCast(y), pal[c]);
            };
        }
    };

    fn at(self: *Sheet, i: usize) Pen {
        return .{ .sheet = self, .ox = i % 8 * cell, .oy = i / 8 * cell };
    }

    /// The color of cell i at (x, y).
    fn get(self: *const Sheet, i: usize, x: usize, y: usize) u32 {
        return self.pixels[(i / 8 * cell + y) * sheet_size + i % 8 * cell + x];
    }

    fn draw(self: *Sheet) void {
        self.ground();
        self.band();
        self.fright();
        self.things();
    }

    /// The street at night: paving stones, sakura petals, a crack and a
    /// drain.
    fn ground(self: *Sheet) void {
        var prng: std.Random.DefaultPrng = .init(42);
        const r = prng.random();
        const base = rgb(0x353b52);
        const mortar = rgb(0x272c3f);
        const light = rgb(0x3f465f);
        const pave = struct {
            fn at(sheet: *Sheet, i: usize, n: usize, rand: std.Random, b: u32, m: u32, l: u32) Pen {
                const c = sheet.at(i);
                for (0..cell) |y| for (0..cell) |x| {
                    // Bricks of 8×8, every other row offset by half.
                    const off: usize = if (y >= 8) 4 else 0;
                    var col = b;
                    if (y % 8 == 0 or (x + off) % 8 == 0) col = m else if (y % 8 == 1 or (x + off) % 8 == 1) col = l;
                    c.px(@intCast(x), @intCast(y), col);
                };
                for (0..n) |_| c.px(rand.intRangeLessThan(i64, 0, cell), rand.intRangeLessThan(i64, 0, cell), m);
                return c;
            }
        }.at;
        _ = pave(self, c_pave, 4, r, base, mortar, light);
        _ = pave(self, c_pave2, 12, r, base, mortar, light);
        const pal = palette(.{ .{ 'p', rgb(0xf6b8cf) }, .{ 'P', rgb(0xe48aae) }, .{ 'w', rgb(0xffe4ee) }, .{ 'm', mortar }, .{ 'g', rgb(0x1b1f2d) }, .{ 'G', rgb(0x4a5170) } });
        pave(self, c_petals, 4, r, base, mortar, light).rows(&pal, 0, &.{
            "",
            "   pP           ",
            "   Pp       wp  ",
            "            pP  ",
            "",
            "       pw       ",
            "       Pp       ",
            "",
            "",
            "  wp            ",
            "  pP      pP    ",
            "          Pw    ",
            "",
            "      pP        ",
            "      PP        ",
        });
        pave(self, c_petals2, 6, r, base, mortar, light).rows(&pal, 0, &.{
            "",
            "",
            "         pw     ",
            "         Pp     ",
            "",
            "   pP           ",
            "   pp           ",
            "",
            "            pP  ",
            "            wP  ",
        });
        pave(self, c_crack, 4, r, base, mortar, light).rows(&pal, 0, &.{
            "",
            "",
            "     m          ",
            "      m         ",
            "      mm        ",
            "        m       ",
            "        m m     ",
            "         m      ",
            "         m      ",
            "          m     ",
        });
        pave(self, c_grate, 2, r, base, mortar, light).rows(&pal, 0, &.{
            "",
            "",
            "",
            "   GGGGGGGGGG   ",
            "   GgGgGgGgGG   ",
            "   GgGgGgGgGG   ",
            "   GgGgGgGgGG   ",
            "   GgGgGgGgGG   ",
            "   GgGgGgGgGG   ",
            "   GGGGGGGGGG   ",
        });
    }

    /// How a bandmate looks: their hair and eyes, the hair's shape above
    /// and beside the body, and what they hold.
    const Look = struct {
        hair: u32,
        hair_dark: u32,
        eye: u32,
        eye2: u32 = 0,
        /// Rows 0 to 8, the hair beside the body from row 9, and what they
        /// hold from row 8.
        head: []const []const u8,
        sides: []const []const u8,
        item: []const []const u8,
        item_colors: []const struct { u8, u32 },
    };

    const looks = [member_count]Look{
        .{
            .hair = 0x93a9cc,
            .hair_dark = 0x6d83aa,
            .eye = 0xd9a441,
            .head = &.{ "", "     HHHHHH     ", "    HHHHHHHH    ", "   HHHHHHHHHH   ", "   HHHHHHHHHH   ", "   HhkkkkkkhH   ", "   HkekkkkEkH   ", "   Hkkkkkkkkh   ", "   hH kkkk Hh   " },
            .sides = &.{"   h        h   "},
            .item = &.{ "             M  ", "             m  ", "            km  " },
            .item_colors = &.{ .{ 'M', 0xd9dde8 }, .{ 'm', 0x3a3f55 } },
        },
        .{
            .hair = 0xf3a5c4,
            .hair_dark = 0xd47ea2,
            .eye = 0x6aa86e,
            .head = &.{ "", "     HHHHHH     ", "    HHHHHHHH    ", "   HHHHHHHHHH   ", "  HHHHHHHHHHHH  ", "  HHhkkkkkkhHH  ", "  HHkekkkkEkHH  ", "  HHkkkkkkkkHH  ", "  HH  kkkk  HH  " },
            .sides = &.{ "  HH        HH  ", "  HH        HH  ", "  hH        Hh  ", "   h        h   " },
            .item = &.{ "              l ", "             l  ", "            l   ", "        GGGl    ", "       GGGGGG   ", "        GGGG    " },
            .item_colors = &.{ .{ 'G', 0xe0465e }, .{ 'l', 0x8f563b } },
        },
        .{
            .hair = 0xd2a679,
            .hair_dark = 0xa97f54,
            .eye = 0x4a8fd6,
            .head = &.{ "", "     HHHHHH     ", "    HHHHHHHH    ", "   HHHHHHHHHH   ", "  HHHHHHHHHHHH  ", "  HHHHkkkkkkHH  ", "  HHkekkkkEkHH  ", "  HHkkkkkkkkHH  ", "  HHH kkkk HHH  " },
            .sides = &.{ "  HHH      HHH  ", "  HHH      HHH  ", "  hHH      HHh  ", "  hH        Hh  " },
            .item = &.{ "               l", "              l ", "             l  ", "            l   ", "       BBBBl    ", "      BBBBBBB   ", "       BBBBB    " },
            .item_colors = &.{ .{ 'B', 0x7b4a8f }, .{ 'l', 0x5c3a24 } },
        },
        .{
            .hair = 0xe6e9f0,
            .hair_dark = 0xa9b0c3,
            .eye = 0xf2c94c,
            .eye2 = 0x56a0d3,
            .head = &.{ "   h        h   ", "   Hh HHHH hH   ", "   HHHHHHHHHH   ", "  HHHHHHHHHHHH  ", "  HHhHHHHHHhHH  ", "  HhkkkkkkkkhH  ", "  HHkekkkkEkHH  ", "  hHkkkkkkkkHh  ", "  hh  kkkk  hh  " },
            .sides = &.{"  hh        hh  "},
            .item = &.{ "              l ", "             l  ", "            l   ", "        TTTl    ", "       TTTTTT   ", "        TTTT    " },
            .item_colors = &.{ .{ 'T', 0x3fc2b5 }, .{ 'l', 0xe8e2d0 } },
        },
        .{
            .hair = 0x3c4170,
            .hair_dark = 0x272a4a,
            .eye = 0xa05ad6,
            .head = &.{ "", "    HHHHHHHH    ", "   HHHHHHHHHH   ", "   HHHHHHHHHH   ", "   HHHHHHHHHH   ", "   HHkkkkkkHH   ", "   HkeekkEEkH   ", "   HkkkkkkkkH   ", "   HH kkkk HH   " },
            .sides = &.{ "   HH      HH   ", "   HH      HH   ", "   hH      Hh   ", "   hh      hh   " },
            .item = &.{ "  d          d  ", "   d        d   ", "    d      d    " },
            .item_colors = &.{.{ 'd', 0xe6c48f }},
        },
    };

    /// The bandmates in their school uniforms, standing and stepping,
    /// facing right.
    fn band(self: *Sheet) void {
        const body = [_][]const u8{ "   kNWWrrWWNk   ", "   kNWWWWWWNk   ", "    NNNNNNNN    ", "    NnNNNNnN    " };
        const legs = [2][3][]const u8{
            .{ "     ss  ss     ", "     bb  bb     ", "    SSSSSSSS    " },
            .{ "    ss    ss    ", "    bb    bb    ", "    SSSSSSSS    " },
        };
        for (looks, 0..) |l, m| {
            var pal = palette(.{
                .{ 'k', rgb(0xf6d5bd) }, .{ 'W', rgb(0xf4f4f8) }, .{ 'N', rgb(0x2b3557) }, .{ 'n', rgb(0x232b47) },
                .{ 'r', rgb(0xd94a5a) }, .{ 's', rgb(0x232b47) }, .{ 'b', rgb(0x3a2a30) }, .{ 'S', shadow_color },
            });
            pal['H'] = rgb(l.hair);
            pal['h'] = rgb(l.hair_dark);
            pal['e'] = rgb(l.eye);
            pal['E'] = rgb(if (l.eye2 == 0) l.eye else l.eye2);
            for (l.item_colors) |entry| pal[entry[0]] = rgb(entry[1]);
            for (0..2) |f| {
                const c = self.at(c_member + m * 2 + f);
                c.rows(&pal, 0, l.head);
                c.rows(&pal, l.head.len, &body);
                c.rows(&pal, l.head.len + body.len, &legs[f]);
                c.rows(&pal, 9, l.sides);
                c.rows(&pal, 8, l.item);
            }
        }
    }

    /// Stage fright, two frames each: static, a crow and a shadow.
    fn fright(self: *Sheet) void {
        var prng: std.Random.DefaultPrng = .init(88);
        const r = prng.random();
        const grays = [_]u32{ rgb(0x8a86a8), rgb(0x6b6788), rgb(0xb2aed0), rgb(0x4d4a66) };
        for (0..2) |f| {
            const c = self.at(c_static + f);
            const ff: f64 = @floatFromInt(f);
            const radius = 5.6 + ff * 0.6;
            for (0..cell) |y| for (0..cell) |x| {
                const dx = @as(f64, @floatFromInt(x)) - 7.5;
                const dy = (@as(f64, @floatFromInt(y)) - 9.5) * (1.1 - ff * 0.15);
                const jag = 0.8 * @sin(std.math.atan2(dy, dx) * 7 + ff * 2);
                if (std.math.hypot(dx, dy) < radius + jag) c.px(@intCast(x), @intCast(y), grays[r.uintLessThan(usize, grays.len)]);
            };
            const eyes = palette(.{ .{ 'w', rgb(0xffffff) }, .{ 'e', rgb(0x16141f) }, .{ 'S', shadow_color } });
            c.rows(&eyes, 8, &.{ "     we  we     ", "     ee  ee     " });
            c.rows(&eyes, 15, &.{"   SSSSSSSSSS   "});
        }
        const pal = palette(.{
            .{ 'b', rgb(0x1e1c2b) }, .{ 'B', rgb(0x34304a) }, .{ 'y', rgb(0xffd95a) }, .{ 'o', rgb(0xf2a03d) },
            .{ 'd', rgb(0x120f1c) }, .{ 'D', rgb(0x2a2340) }, .{ 'r', rgb(0xff4d6a) }, .{ 'S', shadow_color },
        });
        self.at(c_crow).rows(&pal, 0, &.{ "", "", " B            B ", " BB          BB ", " bBB  bbb   BBb ", "  bbBbbbybbBbb  ", "   bbbbbbbbbboo ", "     bbbbbb     ", "      b  b      ", "", "", "", "", "", "     SSSSSS     " });
        self.at(c_crow + 1).rows(&pal, 0, &.{ "", "", "", "", "      bbb       ", "     bbbybb     ", "  BBbbbbbbbboo  ", " BbbbbbbbbbbbB  ", " Bbb   b  b  bB ", " B            B ", "", "", "", "", "     SSSSSS     " });
        const hood = [_][]const u8{ "", "      DDDD      ", "     DddddD     ", "    DddddddD    ", "    DdrddrdD    ", "    DddddddD    ", "    DddddddD    ", "   DdddddddD    ", "   DddddddddD   ", "   DddddddddD   ", "  DdddddddddD   ", "  DddddddddddD  " };
        self.at(c_shadow).rows(&pal, 0, &hood);
        self.at(c_shadow).rows(&pal, hood.len, &.{ "  Dd dd dd dD   ", "   d  d  d  d   ", "", "    SSSSSSSS    " });
        self.at(c_shadow + 1).rows(&pal, 0, &hood);
        self.at(c_shadow + 1).rows(&pal, hood.len, &.{ "  dD dd dd Dd   ", "  d  d  d  d    ", "", "    SSSSSSSS    " });
    }

    /// The note, the pick, stones, band-aids, the puff and the upgrades'
    /// icons.
    fn things(self: *Sheet) void {
        const pal = palette(.{
            .{ 'o', rgb(0x9ff0ff) }, .{ 'O', rgb(0xffffff) }, .{ 'c', rgb(0x3aa7e0) },
            .{ 't', rgb(0x3fc2b5) }, .{ 'T', rgb(0x2a8a80) }, .{ 'g', rgb(0x9a9cab) },
            .{ 'G', rgb(0x6d6f80) }, .{ 'b', rgb(0x8fb4e8) }, .{ 'B', rgb(0x5b7fb8) },
            .{ 'p', rgb(0xf6b8cf) }, .{ 'P', rgb(0xd47ea2) }, .{ 'a', rgb(0xe8b98f) },
            .{ 'A', rgb(0xc9926a) }, .{ 'w', rgb(0xfff6e0) }, .{ 'k', rgb(0x3b3550) },
            .{ 'K', rgb(0x2a2540) }, .{ 'm', rgb(0xd9dde8) }, .{ 'M', rgb(0x3a3f55) },
            .{ 'y', rgb(0xffd95a) }, .{ 'r', rgb(0xe0465e) }, .{ 'l', rgb(0x8f563b) },
            .{ 'v', rgb(0x7b4a8f) }, .{ 'd', rgb(0xe6c48f) }, .{ 'n', rgb(0x2b3557) },
            .{ 'W', rgb(0xd8dde8) },
        });
        self.at(c_note).rows(&pal, 0, &.{ "", "", "        ooo     ", "        oOoo    ", "        o  oo   ", "        o   o   ", "        o       ", "        o       ", "        o       ", "     oooo       ", "    oOOOo       ", "    ooooo       ", "     ooo        " });
        self.at(c_pick).rows(&pal, 0, &.{ "", "", "", "   TTTTTTTTTT   ", "   TttttttttT   ", "   TtOttttttT   ", "    TttttttT    ", "    TttttttT    ", "     TttttT     ", "     TttttT     ", "      TttT      ", "       TT       " });
        const stone_kinds = [_][2]u8{ .{ 'g', 'G' }, .{ 'b', 'B' }, .{ 'p', 'P' } };
        for (stone_kinds, 0..) |kind, i| {
            var p: Palette = @splat(0);
            p['l'] = pal[kind[0]];
            p['L'] = pal[kind[1]];
            p['O'] = pal['O'];
            self.at(c_stone + i).rows(&p, 6, &.{ "      llll      ", "     lOllll     ", "    llllllLL    ", "    lllllLLL    ", "     LLLLLL     " });
        }
        const bandaid = [_][]const u8{ "   aaaaaaaaaa   ", "  aaaawwwwaaaa  ", "  aAaawAAwaaAa  ", "  aaaawAAwaaaa  ", "  aAaawwwwaaAa  ", "   aaaaaaaaaa   " };
        self.at(c_bandaid).rows(&pal, 4, &bandaid);
        var empty: Palette = @splat(0);
        empty['a'] = pal['k'];
        empty['A'] = pal['K'];
        empty['w'] = pal['K'];
        self.at(c_bandaid_empty).rows(&empty, 4, &bandaid);
        for (0..3) |f| {
            const c = self.at(c_puff + f);
            const r: i64 = 3 + @as(i64, @intCast(f)) * 2;
            var y: i64 = -r;
            while (y <= r) : (y += 1) {
                var x: i64 = -r;
                while (x <= r) : (x += 1) {
                    const d = x * x + y * y;
                    if (d <= r * r and (f == 0 or d >= (r - 2) * (r - 2))) c.px(8 + x, 8 + y, pal['w']);
                }
            }
        }
        self.at(c_mic).rows(&pal, 0, &.{ "", "      mmmm      ", "     mWmWmm     ", "     mmWmWm     ", "     mWmWmm     ", "      mmmm      ", "       MM       ", "       MM       ", "       MM       ", "       MM       ", "       MM       ", "       MM       ", "      MMMM      " });
        self.at(c_metronome).rows(&pal, 0, &.{ "", "       ll       ", "       ll   y   ", "      llll y    ", "      llllyl    ", "     lllllyl    ", "     llllylll   ", "    lllllllll   ", "    llllyyllll  ", "   llllllllllll ", "   AAAAAAAAAAAA " });
        self.at(c_guitar).rows(&pal, 0, &.{ "             ll ", "            ll  ", "           l    ", "          l     ", "         l      ", "    rrr l       ", "   rrrrrl       ", "  rrrrkrr       ", "  rrrkkrrr      ", "   rrrrrrrr     ", "  rrrrrrrr      ", "  rrrrrrr       ", "   rrrrr        " });
        self.at(c_bass_icon).rows(&pal, 0, &.{ "              ll", "             ll ", "            l   ", "           l    ", "          l     ", "         l      ", "    vvv l       ", "   vvvvvl       ", "  vvvvkvv       ", "  vvvkkvvv      ", "   vvvvvvvv     ", "  vvvvvvvvv     ", "  vvvvvvvv      ", "   vvvvvv       " });
        self.at(c_drum).rows(&pal, 0, &.{ " d            d ", "  d          d  ", "   d        d   ", "    WWWWWWWW    ", "  WWWWWWWWWWWW  ", "  rWWWWWWWWWWr  ", "  rrrrrrrrrrrr  ", "  ryrrryrrryrr  ", "  rrryrrryrrrr  ", "  rrrrrrrrrrrr  ", "  rrrrrrrrrrrr  ", "   yyyyyyyyyy   " });
        self.at(c_shoe).rows(&pal, 4, &.{ "     nnnnn      ", "     nWnWn      ", "     nnnnn      ", "     nnnnnnn    ", "    nnnnnnnnnn  ", "    WWWWWWWWWW  " });
        self.at(c_stone_icon).rows(&pal, 0, &.{ "", "            y   ", "           yyy  ", "            y   ", "", "     bbbbb      ", "    bObbbbb     ", "   bbbbbbbBB    ", "   bbbbbbBBB  y ", "    BBBBBBB     ", "", "  gggg    pppp  ", " gOgggG  pOpppP ", "  GGGG    PPPP  " });
    }
};

/// How a cell is drawn: flipped, its colors multiplied by `tint` (0xRRGGBB),
/// and as opaque as `alpha`.
const Blit = struct { flip: bool = false, tint: u32 = 0xffffff, alpha: f32 = 1 };

/// The world at the art's resolution, premultiplied BGRA, which the sheet's
/// cells are drawn into.
const Canvas = struct {
    pixels: []u8,
    width: usize,
    height: usize,

    fn clear(self: *Canvas) void {
        @memset(self.pixels, 0);
    }

    /// Blends straight-alpha `color` (0xAARRGGBB) over the pixel (x, y).
    fn blend(self: *Canvas, x: i64, y: i64, color: u32, alpha: f32) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const a = @as(f32, @floatFromInt(color >> 24)) / 255 * alpha;
        if (a <= 0) return;
        const i = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4;
        const keep = 1 - a;
        inline for (.{ 0, 8, 16 }, 0..) |shift, channel| {
            const c = @as(f32, @floatFromInt((color >> shift) & 0xff));
            self.pixels[i + channel] = @intFromFloat(@round(c * a + @as(f32, @floatFromInt(self.pixels[i + channel])) * keep));
        }
        self.pixels[i + 3] = @intFromFloat(@round(255 * a + @as(f32, @floatFromInt(self.pixels[i + 3])) * keep));
    }

    /// Draws cell i of `sheet` with its corner at (x, y), `size` pixels
    /// square, the nearest of the cell's pixels for each.
    fn sprite(self: *Canvas, sheet: *const Sheet, i: usize, x: i64, y: i64, size: usize, how: Blit) void {
        for (0..size) |dy| for (0..size) |dx| {
            var sx = (dx * cell + cell / 2) / size;
            const sy = (dy * cell + cell / 2) / size;
            if (how.flip) sx = cell - 1 - sx;
            const color = tinted(sheet.get(i, sx, sy), how.tint);
            if (color >> 24 != 0) self.blend(x + @as(i64, @intCast(dx)), y + @as(i64, @intCast(dy)), color, how.alpha);
        };
    }

    /// Draws cell i turned by `angle` radians about (cx, cy), `size`
    /// pixels square.
    fn turned(self: *Canvas, sheet: *const Sheet, i: usize, cx: f64, cy: f64, size: f64, angle: f64) void {
        const reach: i64 = @intFromFloat(@ceil(size * 0.75));
        const c = @cos(angle);
        const s = @sin(angle);
        const k = cell / size;
        var dy: i64 = -reach;
        while (dy <= reach) : (dy += 1) {
            var dx: i64 = -reach;
            while (dx <= reach) : (dx += 1) {
                const px = @floor(cx) + @as(f64, @floatFromInt(dx));
                const py = @floor(cy) + @as(f64, @floatFromInt(dy));
                const ox = px + 0.5 - cx;
                const oy = py + 0.5 - cy;
                // Back to the cell, unturned.
                const ux = (ox * c + oy * s) * k + cell / 2.0;
                const uy = (-ox * s + oy * c) * k + cell / 2.0;
                if (ux < 0 or uy < 0 or ux >= cell or uy >= cell) continue;
                const color = sheet.get(i, @intFromFloat(ux), @intFromFloat(uy));
                if (color >> 24 != 0) self.blend(@intFromFloat(px), @intFromFloat(py), color, 1);
            }
        }
    }

    /// Fills the disc of radius r about (cx, cy) with `color`, and rings it
    /// with `edge`.
    fn disc(self: *Canvas, cx: f64, cy: f64, r: f64, color: u32, edge: u32) void {
        const reach: i64 = @intFromFloat(@ceil(r) + 1);
        var dy: i64 = -reach;
        while (dy <= reach) : (dy += 1) {
            var dx: i64 = -reach;
            while (dx <= reach) : (dx += 1) {
                const x = @floor(cx) + @as(f64, @floatFromInt(dx));
                const y = @floor(cy) + @as(f64, @floatFromInt(dy));
                const d = std.math.hypot(x + 0.5 - cx, y + 0.5 - cy);
                if (d > r) continue;
                self.blend(@intFromFloat(x), @intFromFloat(y), if (d > r - 1) edge else color, 1);
            }
        }
    }
};

/// `color` (0xAARRGGBB) with its red, green and blue multiplied by `tint`'s.
fn tinted(color: u32, tint: u32) u32 {
    if (tint == 0xffffff) return color;
    var out = color & 0xff000000;
    inline for (.{ 0, 8, 16 }) |shift| {
        const c = (color >> shift) & 0xff;
        const t = (tint >> shift) & 0xff;
        out |= (c * t / 255) << shift;
    }
    return out;
}

/// The sheet's cells as images, for the screen's icons: each as drawn, and
/// the bandmates as silhouettes.
const Icons = struct {
    /// A frame takes one picture of each lease, so each icon has its own.
    leases: [3][64]drawing.Lease = undefined,
    pixels: [3][64][cell * cell * 4]u8 = undefined,
    levels: [3][64][1]drawing.ImageLevel = undefined,
    identities: [3][64]u64 = @splat(@splat(0)),

    const normal = 0;
    const silhouette = 1;
    const mirrored = 2;

    /// Whether the screen shows cell i as `variant`: the renderers keep at
    /// most 32 pictures, so only those are uploaded.
    fn used(variant: usize, i: usize) bool {
        const member = i >= c_member and i < c_member + 2 * member_count;
        return switch (variant) {
            normal => member or i == c_pick or i == c_stone + 1 or i == c_bandaid or i == c_bandaid_empty or (i >= c_mic and i <= c_stone_icon),
            // Who has yet to join, standing.
            silhouette => member and (i - c_member) % 2 == 0,
            // The title's last two bandmates face the others.
            else => member and (i - c_member) / 2 > 2,
        };
    }

    fn init(sheet: *const Sheet) Icons {
        var self: Icons = .{};
        for (&self.leases) |*row| for (row) |*lease| {
            lease.* = .init(std.Thread.getCurrentId());
        };
        for (0..64) |i| for (0..cell) |y| for (0..cell) |x| for (0..3) |variant| {
            const color = sheet.get(i, if (variant == mirrored) cell - 1 - x else x, y);
            // A silhouette is black, a little less than half opaque.
            const a: f32 = @as(f32, @floatFromInt(color >> 24)) / 255 * @as(f32, if (variant == silhouette) 0.45 else 1);
            const o = (y * cell + x) * 4;
            const px = &self.pixels[variant][i];
            inline for (.{ 0, 8, 16 }, 0..) |shift, channel| {
                const c: f32 = if (variant == silhouette) 0 else @floatFromInt((color >> shift) & 0xff);
                px[o + channel] = @intFromFloat(@round(c * a));
            }
            px[o + 3] = @intFromFloat(@round(255 * a));
        };
        return self;
    }

    /// Hands the images to the renderers of `context`, outside paint.
    fn upload(self: *Icons, context: *ui.Context) !void {
        for (0..3) |variant| for (0..64) |i| if (used(variant, i)) {
            self.levels[variant][i] = .{.{ .pixels = &self.pixels[variant][i], .byte_len = cell * cell * 4, .width = cell, .height = cell, .stride = cell * 4 }};
            self.identities[variant][i] = try drawing.reserveRasterIdentity();
            try context.uploadImage(self.image(variant, i).?);
        };
    }

    fn image(self: *Icons, variant: usize, i: usize) ?drawing.ImageView {
        if (self.identities[variant][i] == 0) return null;
        return .{ .lease = &self.leases[variant][i], .identity = self.identities[variant][i], .levels = &self.levels[variant][i] };
    }

    fn release(self: *Icons, context: *ui.Context) void {
        for (0..3) |variant| for (0..64) |i| if (self.identities[variant][i] != 0) {
            _ = context.releaseImage(self.identities[variant][i]) catch {};
            self.identities[variant][i] = 0;
        };
    }
};

// The sounds: effects synthesized once, and music made as it plays.

const sfx_rate = 32000;

fn midi(m: i32) f64 {
    return 440 * std.math.pow(f64, 2, @as(f64, @floatFromInt(m - 69)) / 12);
}

/// An electric piano's tone: a sine with a soft second harmonic and a
/// bell-like partial that fades fast.
fn ep(f: f64, t: f64) f64 {
    if (t < 0) return 0;
    return (@sin(2 * std.math.pi * f * t) + 0.25 * @sin(4 * std.math.pi * f * t) * @exp(-t * 3) + 0.2 * @sin(2 * std.math.pi * f * 14 * t) * @exp(-t * 25)) * @min(t / 0.004, 1);
}

/// A soft plucked string.
fn pluck(f: f64, t: f64) f64 {
    if (t < 0) return 0;
    return (@sin(2 * std.math.pi * f * t) + 0.5 * @sin(4 * std.math.pi * f * t) * @exp(-t * 6) + 0.25 * @sin(6 * std.math.pi * f * t) * @exp(-t * 10)) * @exp(-t * 2.2) * @min(t / 0.003, 1);
}

/// The game's effects, by the events that play them.
const Effect = enum { sing, hit, calm, stone, level, hurt, beat, choose, join, over };

/// A sound of `seconds`, f of the time and a random source: no click at
/// either end.
fn synth(allocator: std.mem.Allocator, seconds: f64, r: std.Random, comptime f: fn (f64, std.Random) f64) !*audio.Sound {
    const samples = try allocator.alloc(f32, @intFromFloat(seconds * sfx_rate));
    defer allocator.free(samples);
    for (samples, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / sfx_rate;
        const edge = @min(@min(t / 0.002, (seconds - t) / 0.01), 1);
        s.* = @floatCast(f(t, r) * edge);
    }
    return audio.Sound.fromSamples(allocator, sfx_rate, 1, samples);
}

fn noise(r: std.Random) f64 {
    return r.float(f64) * 2 - 1;
}

const effects = struct {
    // A sung "ah": a fifth up, with a little vibrato.
    fn sing(t: f64, _: std.Random) f64 {
        const f = 660 * (1 + 0.012 * @sin(2 * std.math.pi * 7 * t));
        return (@sin(2 * std.math.pi * f * t) + 0.3 * @sin(4 * std.math.pi * f * t) + 0.15 * @sin(6 * std.math.pi * f * t)) * @exp(-t * 14) * @min(t * 60, 1) * 0.16;
    }
    fn hit(t: f64, r: std.Random) f64 {
        return noise(r) * @exp(-t * 80) * 0.25;
    }
    fn calm(t: f64, r: std.Random) f64 {
        return (@sin(2 * std.math.pi * (300 + 1500 * t) * t) * 0.4 + noise(r) * 0.15 * @exp(-t * 40)) * @exp(-t * 16);
    }
    // A pebble's click.
    fn stone(t: f64, _: std.Random) f64 {
        return (@sin(2 * std.math.pi * 2300 * t) + 0.5 * @sin(2 * std.math.pi * 3400 * t)) * @exp(-t * 70) * 0.22;
    }
    fn level(t: f64, _: std.Random) f64 {
        var s: f64 = 0;
        for ([_]f64{ 587.33, 739.99, 880, 1174.66 }, 0..) |f, i| {
            const nt = t - @as(f64, @floatFromInt(i)) * 0.08;
            if (nt > 0) s += ep(f, nt) * @exp(-nt * 3);
        }
        return s * 0.14;
    }
    fn hurt(t: f64, r: std.Random) f64 {
        return (@sin(2 * std.math.pi * (160 - 220 * t) * t) * 0.7 + noise(r) * 0.3) * @exp(-t * 12) * 0.45;
    }
    // Taki's beat: a kick and a crash.
    fn beat(t: f64, r: std.Random) f64 {
        const kick = @sin(2 * std.math.pi * (55 + 90 * @exp(-t * 30)) * t) * @exp(-t * 9);
        return (kick * 0.8 + noise(r) * 0.3 * @exp(-t * 5)) * 0.45;
    }
    fn choose(t: f64, _: std.Random) f64 {
        return (ep(880, t) + 0.6 * ep(1318.5, t - 0.05)) * @exp(-t * 7) * 0.15;
    }
    // A bandmate joins: a strummed D major chord.
    fn join(t: f64, _: std.Random) f64 {
        var s: f64 = 0;
        for ([_]i32{ 50, 57, 62, 66, 69, 74 }, 0..) |m, i| {
            const nt = t - @as(f64, @floatFromInt(i)) * 0.025;
            if (nt > 0) s += pluck(midi(m), nt);
        }
        return s * 0.12;
    }
    fn over(t: f64, _: std.Random) f64 {
        var s: f64 = 0;
        for ([_]i32{ 74, 71, 69, 66, 62 }, 0..) |m, i| {
            const nt = t - @as(f64, @floatFromInt(i)) * 0.25;
            if (nt > 0) s += ep(midi(m), nt) * @exp(-nt * 2.5);
        }
        return s * 0.15;
    }
};

const effect_lengths = std.EnumArray(Effect, f64).init(.{ .sing = 0.16, .hit = 0.05, .calm = 0.22, .stone = 0.06, .level = 0.8, .hurt = 0.3, .beat = 0.6, .choose = 0.35, .join = 1.4, .over = 1.6 });

/// The game's effects and its music.
const Sounds = struct {
    engine: *audio.Engine,
    effects: std.EnumArray(Effect, *audio.Sound),
    tune: *Tune,
    music: audio.Player,
    rng: std.Random.DefaultPrng,
    /// Stones picked up in a row, and when the last one was, in steps.
    stones: u32 = 0,
    last_stone: u64 = 0,

    fn init(allocator: std.mem.Allocator, engine: *audio.Engine) !Sounds {
        var rng: std.Random.DefaultPrng = .init(97);
        var made: std.EnumArray(Effect, *audio.Sound) = undefined;
        var count: usize = 0;
        errdefer for (std.enums.values(Effect)[0..count]) |e| made.get(e).release();
        inline for (comptime std.enums.values(Effect)) |e| {
            made.set(e, try synth(allocator, effect_lengths.get(e), rng.random(), @field(effects, @tagName(e))));
            count += 1;
        }
        const tune = try Tune.create(allocator);
        errdefer allocator.destroy(tune);
        const music = try engine.newPlayer(tune.decoder());
        // The first bar is an intro: then the rest loops.
        music.setLoopRange(@intFromFloat(@round(bar_len * std.time.ns_per_s)), 0);
        music.setVolume(0.5);
        return .{ .engine = engine, .effects = made, .tune = tune, .music = music, .rng = rng };
    }

    fn deinit(self: *Sounds) void {
        self.music.close();
        self.tune.destroy();
        for (std.enums.values(Effect)) |e| self.effects.get(e).release();
    }

    /// Plays the sounds of what happened in step n, a little different each
    /// time, as games vary effects that play often. Stones picked up in a
    /// row climb in pitch.
    fn play(self: *Sounds, events: []const Event, n: u64) void {
        var sang = false;
        const r = self.rng.random();
        for (events) |e| {
            var volume: f64 = 1;
            var speed: f64 = 0.94 + r.float(f64) * 0.12;
            const effect: Effect = switch (e) {
                .sing => blk: {
                    // One for a volley.
                    if (sang) continue;
                    sang = true;
                    volume = 0.7;
                    // On the notes of the tune's scale.
                    const scale = [_]f64{ 0, 2, 4, 7, 9 };
                    speed = std.math.pow(f64, 2, scale[r.uintLessThan(usize, scale.len)] / 12);
                    break :blk .sing;
                },
                .hit => blk: {
                    volume = 0.5;
                    break :blk .hit;
                },
                .kill => blk: {
                    volume = 0.55;
                    break :blk .calm;
                },
                .stone => blk: {
                    if (n -| self.last_stone > 30) self.stones = 0;
                    self.last_stone = n;
                    speed = std.math.pow(f64, 2, @as(f64, @floatFromInt(@min(self.stones, 12))) / 12);
                    self.stones += 1;
                    break :blk .stone;
                },
                .level => blk: {
                    speed = 1;
                    break :blk .level;
                },
                .hurt => .hurt,
                .beat => .beat,
                .choose => blk: {
                    speed = 1;
                    break :blk .choose;
                },
                .join => blk: {
                    speed = 1;
                    break :blk .join;
                },
                .over => blk: {
                    speed = 1;
                    break :blk .over;
                },
            };
            const player = self.engine.createPlayer(self.effects.get(effect)) catch continue;
            player.setVolume(volume);
            player.setSpeed(speed);
            player.play();
            player.release();
        }
    }

    /// Tells the music who plays: each bandmate adds their part.
    fn setBand(self: *Sounds, band: []const usize) void {
        var mask: u32 = 0;
        for (band) |m| mask |= @as(u32, 1) << @intCast(m);
        self.tune.band.store(mask, .monotonic);
    }
};

// The tune: a lo-fi arrangement in E major and 6/8, with vinyl crackle and
// a wavering tape, made as it plays. Tomori hums the melody over a Rhodes;
// Anon brings guitar arpeggios, Soyo the bass, Taki the drums and Rāna an
// echo of the melody an octave up. Its first bar, the Rhodes alone, is an
// intro.

const tune_rate = 22050;
const eighth_len = 0.33;
const bar_len = 6 * eighth_len;
const tune_bars = 9;

/// The parts' voices.
const Voice = enum { rhodes, hum, guitar, bass, drums, echo };
const Drum = enum { none, kick, snare, hat };

/// A note or a drum of a part, at a time of the loop, in seconds; a hummed
/// note lasts `dur`.
const Hit = struct { t: f64, freqs: [4]f64 = @splat(0), count: usize = 0, dur: f64 = 0, drum: Drum = .none, vel: f64 };

/// What one instrument plays, by whom.
const Part = struct { member: usize, voice: Voice, hits: std.ArrayList(Hit) = .empty };

// Chords, as the Rhodes voices them: from the bass up.
const emaj7 = [4]i32{ 52, 56, 59, 63 };
const fsm7 = [4]i32{ 54, 57, 61, 64 };
/// Over F♯.
const dmaj7 = [4]i32{ 54, 57, 61, 62 };
const gsm7 = [4]i32{ 56, 59, 63, 66 };
const b7sus4 = [4]i32{ 59, 64, 66, 69 };
const badd9 = [4]i32{ 59, 61, 63, 66 };
const fs7 = [4]i32{ 54, 58, 61, 64 };
const csm7 = [4]i32{ 56, 59, 61, 64 };
const harmony = [8][2][4]i32{ .{ emaj7, emaj7 }, .{ emaj7, fsm7 }, .{ dmaj7, dmaj7 }, .{ gsm7, b7sus4 }, .{ badd9, badd9 }, .{ badd9, fs7 }, .{ csm7, fs7 }, .{ badd9, fs7 } };
/// The bass's roots, a half bar each, and the intro's.
const roots = [8][2]i32{ .{ 40, 40 }, .{ 40, 42 }, .{ 42, 42 }, .{ 44, 47 }, .{ 47, 47 }, .{ 47, 40 }, .{ 49, 42 }, .{ 47, 40 } };
const intro_root = 40;
/// The melody, a bar each: its notes as eighth, MIDI note and eighths long.
const melody = [8][]const [3]i32{
    &.{ .{ 0, 71, 3 }, .{ 3, 71, 1 }, .{ 4, 73, 1 }, .{ 5, 71, 1 } },
    &.{ .{ 0, 73, 1 }, .{ 1, 74, 1 }, .{ 2, 71, 1 }, .{ 3, 73, 3 } },
    &.{ .{ 0, 73, 2 }, .{ 2, 74, 1 }, .{ 3, 73, 3 } },
    &.{ .{ 0, 68, 3 }, .{ 3, 76, 1 }, .{ 4, 75, 2 } },
    &.{.{ 0, 75, 6 }},
    &.{ .{ 0, 75, 3 }, .{ 3, 66, 3 } },
    &.{ .{ 0, 66, 1 }, .{ 1, 75, 1 }, .{ 2, 73, 1 }, .{ 3, 71, 1 }, .{ 4, 66, 1 }, .{ 5, 70, 1 } },
    &.{.{ 0, 71, 6 }},
};

const Tune = struct {
    allocator: std.mem.Allocator,
    pos: u64 = 0,
    /// Who plays, by bit.
    band: std.atomic.Value(u32) = .init(0),
    /// Fade the bandmates in and out, per sample.
    gains: [member_count]f64 = @splat(0),
    parts: [zio.fields(Voice).len]Part,
    rng: std.Random.DefaultPrng = .init(55),

    fn create(allocator: std.mem.Allocator) !*Tune {
        const self = try allocator.create(Tune);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .parts = .{
            .{ .member = vocalist, .voice = .rhodes },
            .{ .member = vocalist, .voice = .hum },
            .{ .member = guitarist, .voice = .guitar },
            .{ .member = bassist, .voice = .bass },
            .{ .member = drummer, .voice = .drums },
            .{ .member = lead, .voice = .echo },
        } };
        errdefer for (&self.parts) |*p| p.hits.deinit(allocator);
        const at = struct {
            fn at(bar: usize, eighth: usize) f64 {
                return @as(f64, @floatFromInt(bar * 6 + eighth)) * eighth_len;
            }
        }.at;
        try self.add(.rhodes, chordHit(0, fs7, 1));
        try self.add(.bass, noteHit(0, intro_root, 1));
        for (1..tune_bars) |b| {
            for (0..2) |half| {
                const chord = harmony[b - 1][half];
                const root = roots[b - 1][half];
                const e = half * 3;
                // The Rhodes, on each half bar, softer on the second.
                try self.add(.rhodes, chordHit(at(b, e), chord, 1 - 0.3 * @as(f64, @floatFromInt(half))));
                // Anon's arpeggio, up the chord an octave higher.
                for ([_]usize{ 1, 2, 3 }, 0..) |k, i| try self.add(.guitar, noteHit(at(b, e + i), chord[k] + 12, 1 - 0.2 * @as(f64, @floatFromInt(i))));
                // Soyo: the root, then its fifth.
                try self.add(.bass, noteHit(at(b, e), root, 1));
                try self.add(.bass, noteHit(at(b, e + 2), root + 7, 0.6));
            }
            // Taki: half time, a kick on the bar, the snare on its middle.
            try self.add(.drums, .{ .t = at(b, 0), .drum = .kick, .vel = 1 });
            try self.add(.drums, .{ .t = at(b, 3), .drum = .snare, .vel = 1 });
            try self.add(.drums, .{ .t = at(b, 5), .drum = .kick, .vel = 0.5 });
            for ([_]f64{ 0.9, 0.4, 0.6, 0.9, 0.4, 0.6 }, 0..) |vel, i| try self.add(.drums, .{ .t = at(b, i) + 0.002, .drum = .hat, .vel = vel });
            for (melody[b - 1]) |n| {
                var h = noteHit(at(b, @intCast(n[0])), n[1], 1);
                h.dur = @as(f64, @floatFromInt(n[2])) * eighth_len - 0.04;
                try self.add(.hum, h);
                // Rāna's echo: an eighth later, an octave up.
                h.t += eighth_len;
                h.freqs[0] = midi(n[1] + 12);
                try self.add(.echo, h);
            }
        }
        for (&self.parts) |*p| std.mem.sort(Hit, p.hits.items, {}, struct {
            fn less(_: void, a: Hit, b: Hit) bool {
                return a.t < b.t;
            }
        }.less);
        return self;
    }

    fn destroy(self: *Tune) void {
        for (&self.parts) |*p| p.hits.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn add(self: *Tune, voice: Voice, hit: Hit) !void {
        try self.parts[@backingInt(voice)].hits.append(self.allocator, hit);
    }

    fn noteHit(t: f64, m: i32, vel: f64) Hit {
        var h: Hit = .{ .t = t, .vel = vel, .count = 1 };
        h.freqs[0] = midi(m);
        return h;
    }
    fn chordHit(t: f64, chord: [4]i32, vel: f64) Hit {
        var h: Hit = .{ .t = t, .vel = vel, .count = 4 };
        for (chord, 0..) |m, i| h.freqs[i] = midi(m);
        return h;
    }

    fn frames() u64 {
        return @intFromFloat(@round(tune_bars * bar_len * tune_rate));
    }

    fn decoder(self: *Tune) audio.Decoder {
        return .{ .context = self, .vtable = &.{ .read = read, .setPosition = setPosition, .deinit = deinitDecoder }, .sample_rate = tune_rate, .channels = 2, .frames = frames() };
    }

    fn setPosition(ptr: *anyopaque, frame: u64) audio.Error!void {
        const self: *Tune = @ptrCast(@alignCast(ptr));
        self.pos = frame;
    }

    /// The player lets go of the tune as it closes; the game frees it.
    fn deinitDecoder(_: *anyopaque) void {}

    fn read(ptr: *anyopaque, buffer: []f32) audio.Error!usize {
        const self: *Tune = @ptrCast(@alignCast(ptr));
        // Tomori always plays.
        const band = self.band.load(.monotonic) | 1;
        const r = self.rng.random();
        var n: usize = 0;
        while (n + 2 <= buffer.len and self.pos < frames()) : (n += 2) {
            const sec = @as(f64, @floatFromInt(self.pos)) / tune_rate;
            // The tape's wow: the pitch wavers a little.
            const wsec = sec + 0.0018 * @sin(2 * std.math.pi * 0.55 * sec);
            for (&self.gains, 0..) |*g, m| {
                const want: f64 = if (band & (@as(u32, 1) << @intCast(m)) != 0) 1 else 0;
                g.* += (want - g.*) * 0.0002;
            }
            var l: f64 = 0;
            var rr: f64 = 0;
            for (&self.parts) |*p| {
                const g = self.gains[p.member];
                if (g < 0.001) continue;
                const hits = p.hits.items;
                // The hit sounding and those before it, still ringing.
                var lo: usize = 0;
                var hi: usize = hits.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (hits[mid].t <= wsec) lo = mid + 1 else hi = mid;
                }
                const i = lo;
                if (i == 0) continue;
                var v: f64 = 0;
                var j = i -| 4;
                while (j < i) : (j += 1) v += sound(p.voice, hits[j], wsec - hits[j].t);
                v *= g;
                const pan: f64 = switch (p.voice) {
                    .guitar => -0.35,
                    .drums => 0.05,
                    .echo => 0.4,
                    else => 0,
                };
                l += v * (1 - pan);
                rr += v * (1 + pan);
            }
            // Vinyl: a soft hiss, and now and then a crackle.
            var crackle = 0.004 * (r.float(f64) * 2 - 1);
            if (r.uintLessThan(u32, 2500) == 0) crackle += (r.float(f64) * 2 - 1) * 0.1;
            // Warm: soft saturation.
            buffer[n] = @floatCast(std.math.tanh(l * 0.9) + crackle);
            buffer[n + 1] = @floatCast(std.math.tanh(rr * 0.9) + crackle);
            self.pos += 1;
        }
        return n;
    }
};

/// Noise that is the same at the same time.
fn noiseAt(x: f64) f64 {
    const v = @sin(x * 12.9898) * 43758.5453;
    return (v - @floor(v)) * 2 - 1;
}

/// A hummed note: a soft "oo" with a vibrato that grows, held for dur, then
/// let go.
fn voiced(f: f64, t: f64, dur: f64) f64 {
    if (t < 0) return 0;
    var env = @min(t / 0.05, 1);
    if (t > dur) env *= @exp(-(t - dur) * 12) else env *= 1 - 0.2 * t / @max(dur, 0.1);
    const depth = f * 0.007 * @min(t / 0.35, 1);
    const ph = 2 * std.math.pi * f * t + depth / 5.5 * @sin(2 * std.math.pi * 5.5 * t);
    return (@sin(ph) + 0.3 * @sin(2 * ph) + 0.08 * @sin(3 * ph)) * env;
}

/// What hit h of a voice sounds like, dt seconds after it.
fn sound(voice: Voice, h: Hit, dt: f64) f64 {
    switch (h.drum) {
        .kick => return @sin(2 * std.math.pi * (48 + 70 * @exp(-dt * 35)) * dt) * @exp(-dt * 8) * @min(dt / 0.002, 1) * 0.8 * h.vel,
        .snare => return (noiseAt(dt * 977) * 0.45 * @exp(-dt * 16) + @sin(2 * std.math.pi * 185 * dt) * 0.25 * @exp(-dt * 25)) * 0.45 * h.vel,
        .hat => return noiseAt(dt * 1931) * @exp(-dt * 70) * 0.14 * h.vel,
        .none => {},
    }
    var s: f64 = 0;
    for (h.freqs[0..h.count], 0..) |f, i| switch (voice) {
        // The chord strummed a little.
        .rhodes => {
            const at = dt - @as(f64, @floatFromInt(i)) * 0.014;
            s += ep(f, at) * @exp(-@max(at, 0) * 0.9) * 0.16;
        },
        .hum => s += voiced(f, dt, h.dur) * 0.22,
        .guitar => s += pluck(f, dt) * 0.16,
        .bass => if (dt > 0) {
            s += (@sin(2 * std.math.pi * f * dt) + 0.3 * @sin(4 * std.math.pi * f * dt)) * @exp(-dt * 2) * @min(dt / 0.01, 1) * 0.5;
        },
        // A clean guitar, far away.
        .echo => if (dt > 0) {
            s += (@sin(2 * std.math.pi * f * dt) + 0.2 * @sin(4 * std.math.pi * f * dt)) * @exp(-dt * 3.5) * @min(dt / 0.004, 1) * 0.06;
        },
        .drums => {},
    };
    return s * h.vel;
}

// The game.

const white: u32 = 0xffffff;
const muted: u32 = 0xc8c4dc;
const gold: u32 = 0xffd95a;
const pink: u32 = 0xf6b8cf;
const night: u32 = 0x272c3f;

/// The street's tile at (x, y): paving, here and there sakura petals, a
/// crack or a drain.
fn tileAt(x: i64, y: i64) usize {
    var n = @as(u64, @bitCast(x)) *% 0x9e3779b97f4a7c15 ^ @as(u64, @bitCast(y)) *% 0xc2b2ae3d27d4eb4f;
    n = (n ^ n >> 31) *% 0xbf58476d1ce4e5b9;
    const v = (n ^ n >> 27) % 100;
    if (v < 3) return c_petals;
    if (v < 5) return c_petals2;
    if (v < 7) return c_crack;
    if (v < 8) return c_grate;
    if (v < 50) return c_pave2;
    return c_pave;
}

/// What a frame of the world shows: the camera, how many DIPs a pixel of
/// the art takes, and the corner and size of the picture, in pixels of the
/// world.
const Scene = struct {
    cam_x: f64,
    cam_y: f64,
    zoom: f32,
    left: i64,
    top: i64,
    width: usize,
    height: usize,
    alpha: f64,
    tomori: Vec,
};

/// Where the upgrades offered show in a view of w×h.
fn cards(n: usize, w: f32, h: f32) [3]view.Rect {
    const gap = 14;
    const ch = 176;
    const cw = @min(200, (w - 40 - gap * 2) / 3);
    const nf: f32 = @floatFromInt(n);
    const total = nf * cw + (nf - 1) * gap;
    const x = (w - total) / 2;
    const y = h / 2 - ch / 2 + 16;
    var out: [3]view.Rect = undefined;
    for (&out, 0..) |*c, i| c.* = .{ .x = x + @as(f32, @floatFromInt(i)) * (cw + gap), .y = y, .width = cw, .height = ch };
    return out;
}

fn clockText(buffer: []u8, seconds: f64) []const u8 {
    const s: u64 = @intFromFloat(seconds);
    return std.fmt.bufPrint(buffer, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

/// `a` faded toward `b` as `k` goes from 1 to 0.
fn fade(a: u32, b: u32, k: f64) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const x: f64 = @floatFromInt((a >> shift) & 0xff);
        const y: f64 = @floatFromInt((b >> shift) & 0xff);
        out |= @as(u32, @intFromFloat(@round(y + (x - y) * std.math.clamp(k, 0, 1)))) << shift;
    }
    return out;
}

/// Widths of lines of text, measured by the system once each, so text
/// centers where the renderer draws it. Without an engine, as in tests,
/// widths are estimated.
const Widths = struct {
    allocator: std.mem.Allocator,
    engine: ?*text_layout.Engine = null,
    known: std.StringHashMapUnmanaged(f32) = .empty,

    fn deinit(self: *Widths) void {
        self.clear();
        self.known.deinit(self.allocator);
    }

    fn clear(self: *Widths) void {
        var keys = self.known.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.known.clearRetainingCapacity();
    }

    fn get(self: *Widths, text: []const u8, font: ui.Font) f32 {
        const estimate = (view.Measurer{}).textSize(text, font).width;
        const engine = self.engine orelse return estimate;
        var buffer: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buffer, "{d}/{d}/{s}", .{ font.size, @backingInt(font.weight), text }) catch return estimate;
        if (self.known.get(key)) |w| return w;
        const weights = [_]u32{ 400, 500, 600, 700 };
        const layout = engine.layout(text, .{ .size = font.size, .weight = weights[@backingInt(font.weight)] }) catch return estimate;
        defer layout.close() catch {};
        var w: f32 = 0;
        for (layout.lines() catch return estimate) |line| w = @max(w, line.width);
        // The clock and the numbers change: forget them now and then.
        if (self.known.count() >= 512) self.clear();
        const owned = self.allocator.dupe(u8, key) catch return w;
        self.known.put(self.allocator, owned, w) catch self.allocator.free(owned);
        return w;
    }
};

fn dim(frame: *ui.Frame, r: view.Rect) void {
    frame.roundedRect(r, 0, .{ .r = 14, .g = 12, .b = 28, .a = 179 });
}

/// The game game.View runs: `update` steps the world with the input,
/// `draw` draws it.
const Mayoi = struct {
    allocator: std.mem.Allocator,
    world: World,
    sheet: Sheet = .{},
    icons: ?*Icons = null,
    sounds: ?*Sounds = null,
    /// The player wants music (M), and it plays.
    music: bool = true,
    sounding: bool = false,
    /// Paused by the player; the world did not step, so nothing moves
    /// between steps.
    paused: bool = false,
    frozen: bool = false,
    steps: u64 = 0,
    /// The upgrade chosen with keys or a pad.
    pick: usize = 0,
    pads: gamepad.Gamepads = .{},
    pad: gamepad.State = .{},
    rng: std.Random.DefaultPrng = .init(1),
    host: ?*view.Host = null,
    /// The world's picture, the scene it shows, and the scene to draw next.
    image: ?ui.PixelImage = null,
    shown: ?Scene = null,
    next: ?Scene = null,
    queued: bool = false,
    widths: Widths,

    fn init(allocator: std.mem.Allocator, seed: u64) Mayoi {
        var self: Mayoi = .{ .allocator = allocator, .world = .init(allocator, seed), .widths = .{ .allocator = allocator } };
        self.sheet.draw();
        return self;
    }

    fn deinit(self: *Mayoi) void {
        self.widths.deinit();
        self.world.deinit();
        self.pads.deinit();
        if (self.image) |*image| image.deinit();
    }

    fn start(self: *Mayoi) void {
        self.world.reset();
        self.paused = false;
        self.frozen = false;
        self.pick = 0;
    }

    /// Plays or pauses the music, as the game wants it.
    fn playMusic(self: *Mayoi, on: bool) void {
        if (on == self.sounding) return;
        self.sounding = on;
        const sounds = self.sounds orelse return;
        if (on) sounds.music.play() else sounds.music.pause();
    }

    /// Reads the keys, the pointer and the gamepad, and steps the world
    /// unless it waits for the player, then plays what happened.
    pub fn update(self: *Mayoi, in: *const game.Input) void {
        const w = &self.world;
        self.steps += 1;
        const prev = self.pad;
        var buffer: [gamepad.max_pads]gamepad.Pad = undefined;
        const pads = self.pads.pads(self.steps * std.time.ns_per_s / game.rate, &buffer);
        const pad: gamepad.State = if (pads.len > 0) pads[0].state() else .{};
        self.pad = pad;
        const confirm = in.pressed(.space) or in.pressed(.enter) or pad.justPressed(prev, .south);
        if (in.pressed(.m)) self.music = !self.music;
        self.frozen = true;
        switch (w.state) {
            .title => if (confirm or in.pointerPressed(0) or pad.justPressed(prev, .start)) self.start(),
            .over => {
                if (w.over_time > 0.8 and (confirm or in.pointerPressed(0) or pad.justPressed(prev, .start))) self.start();
                w.step(step_time);
            },
            .choosing => self.choose(in, pad, prev, confirm),
            .playing => {
                if (in.pressed(.escape) or in.pressed(.p) or pad.justPressed(prev, .start)) self.paused = !self.paused;
                if (self.paused and (confirm or in.pointerPressed(0))) self.paused = false;
                var move: Vec = .{};
                if (in.down(.left) or in.down(.a) or pad.pressed(.left)) move.x -= 1;
                if (in.down(.right) or in.down(.d) or pad.pressed(.right)) move.x += 1;
                if (in.down(.up) or in.down(.w) or pad.pressed(.up)) move.y -= 1;
                if (in.down(.down) or in.down(.s) or pad.pressed(.down)) move.y += 1;
                const stick = pad.leftStick();
                move = move.add(.{ .x = stick.x, .y = stick.y });
                if (move.len() > 1) move = move.norm();
                w.move = move;
                // Without the keyboard, the player is elsewhere: wait for
                // them.
                if (!self.paused and in.focused()) {
                    w.step(step_time);
                    self.frozen = false;
                }
            },
        }
        // The music plays with the game: not before it, nor while it waits
        // for a player who paused it or is elsewhere.
        self.playMusic(self.music and w.state != .title and in.focused() and !(w.state == .playing and self.paused));
        if (self.sounds) |sounds| {
            sounds.setBand(w.band[0..w.band_len]);
            if (w.events.items.len > 0) sounds.play(w.events.items, self.steps);
        }
        w.events.clearRetainingCapacity();
    }

    /// Takes the upgrade the player picks: by its number, a click, or
    /// moving to it and confirming.
    fn choose(self: *Mayoi, in: *const game.Input, pad: gamepad.State, prev: gamepad.State, confirmed: bool) void {
        const w = &self.world;
        var confirm = confirmed;
        const n = w.choices_len;
        for ([_]z.KeyCode{ .digit1, .digit2, .digit3 }, 0..) |k, i| if (i < n and in.pressed(k)) {
            self.pick = i;
            confirm = true;
        };
        const was = prev.leftStick().x;
        const x = pad.leftStick().x;
        const left = in.pressed(.left) or in.pressed(.a) or pad.justPressed(prev, .left) or (was > -0.5 and x <= -0.5);
        const right = in.pressed(.right) or in.pressed(.d) or pad.justPressed(prev, .right) or (was < 0.5 and x >= 0.5);
        if (left) self.pick = (self.pick + n - 1) % n;
        if (right) self.pick = (self.pick + 1) % n;
        const size = in.size();
        const p = in.pointer();
        if (p.over) for (cards(n, size.width, size.height)[0..n], 0..) |c, i| {
            if (p.x >= c.x and p.x < c.x + c.width and p.y >= c.y and p.y < c.y + c.height) {
                self.pick = i;
                if (in.pointerPressed(0)) confirm = true;
            }
        };
        if (confirm) {
            w.choose(self.pick);
            self.pick = 0;
        }
    }

    /// How many DIPs a pixel of the art takes: a whole number of the
    /// screen's, about 200 of them across the view's shorter side.
    fn zoom(scale: f32, r: view.Rect) f32 {
        const k = @max(2, @round(@min(r.width, r.height) * scale / 200));
        return k / scale;
    }

    /// Draws the world through a camera that follows Tomori, then the HUD
    /// and what waits for the player over it.
    pub fn draw(self: *Mayoi, frame: *ui.Frame, r: view.Rect, step_alpha: f64) !void {
        const w = &self.world;
        const alpha = if (self.frozen) 1 else step_alpha;
        frame.rect(r, night);
        const zf = zoom(frame.size.scale, r);
        w.view = .{ .x = r.width / 2 / zf, .y = r.height / 2 / zf };
        const tomori = w.prev.lerp(w.pos, alpha);
        var cam_x = tomori.x;
        var cam_y = tomori.y - 6;
        if (w.shake > 0) {
            const rand = self.rng.random();
            cam_x += (rand.float(f64) * 2 - 1) * w.shake * 10;
            cam_y += (rand.float(f64) * 2 - 1) * w.shake * 10;
        }
        const half_w = r.width / 2 / zf;
        const half_h = r.height / 2 / zf;
        const left: i64 = @intFromFloat(@floor(cam_x - half_w) - 1);
        const top: i64 = @intFromFloat(@floor(cam_y - half_h) - 1);
        self.next = .{
            .cam_x = cam_x,
            .cam_y = cam_y,
            .zoom = zf,
            .left = left,
            .top = top,
            .width = @intFromFloat(@ceil(r.width / zf) + 3),
            .height = @intFromFloat(@ceil(r.height / zf) + 3),
            .alpha = alpha,
            .tomori = tomori,
        };
        // The picture drawn last frame, where its camera saw it.
        if (self.shown) |s| if (self.image) |*image| if (image.view()) |picture| {
            const snap = struct {
                fn at(v: f32, pixels: f32) f32 {
                    return @round(v * pixels) / pixels;
                }
            }.at;
            const x = snap(r.x + r.width / 2 + @as(f32, @floatCast(@as(f64, @floatFromInt(s.left)) - s.cam_x)) * s.zoom, frame.size.scale);
            const y = snap(r.y + r.height / 2 + @as(f32, @floatCast(@as(f64, @floatFromInt(s.top)) - s.cam_y)) * s.zoom, frame.size.scale);
            try frame.pushClip(r);
            defer frame.popClip() catch {};
            try frame.image(.{ .x = x, .y = y, .width = @as(f32, @floatFromInt(s.width)) * s.zoom, .height = @as(f32, @floatFromInt(s.height)) * s.zoom }, picture, .{ .sampling = .nearest });
        };
        // Numbers of damage, in the screen's pixels, sharp at any zoom.
        const cam = self.shown orelse self.next.?;
        for (w.popups.items) |p| {
            const x = r.x + r.width / 2 + @as(f32, @floatCast(p.pos.x - cam.cam_x)) * cam.zoom;
            const y = r.y + r.height / 2 + @as(f32, @floatCast(p.pos.y - p.t * 20 - cam.cam_y)) * cam.zoom;
            const k = 1 - p.t / 0.6;
            self.center(frame, x + 1, y + 1 - 9, p.label(), 13, .bold, fade(0x000000, night, k * 0.6));
            self.center(frame, x, y - 9, p.label(), 13, .bold, fade(0xfff0c8, night, k));
        }
        if (w.state != .title) self.drawHud(frame, r);
        switch (w.state) {
            .title => self.drawTitle(frame, r),
            .choosing => self.drawChoices(frame, r),
            .over => self.drawOver(frame, r),
            .playing => if (self.frozen) {
                dim(frame, r);
                self.center(frame, r.x + r.width / 2, r.y + r.height / 2 - 24 - 18, "Paused", 28, .bold, white);
                self.center(frame, r.x + r.width / 2, r.y + r.height / 2 + 14 - 9, "Click or press Space to play", 14, .regular, muted);
            },
        }
        self.requestRender();
    }

    /// A line of text centered at x, its top at y.
    fn center(self: *Mayoi, frame: *ui.Frame, x: f32, y: f32, text: []const u8, size: f32, weight: ui.Font.Weight, rgb_color: u32) void {
        const font: ui.Font = .{ .size = size, .weight = weight };
        const w = self.widths.get(text, font);
        frame.labelFont(.{ .x = x - w / 2, .y = y, .width = w + 8, .height = size * 1.4 }, text, rgb_color, font);
    }

    fn icon(self: *Mayoi, frame: *ui.Frame, i: usize, dst: view.Rect, silhouette: bool) void {
        const icons = self.icons orelse return;
        const picture = icons.image(if (silhouette) Icons.silhouette else Icons.normal, i) orelse return;
        frame.image(dst, picture, .{ .sampling = .nearest }) catch {};
    }

    /// The experience bar, the band-aids, the time, the band, the stones
    /// collected, and who just joined.
    fn drawHud(self: *Mayoi, frame: *ui.Frame, r: view.Rect) void {
        const w = &self.world;
        var bar: view.Rect = .{ .x = r.x, .y = r.y, .width = r.width, .height = 8 };
        frame.roundedRect(bar, 0, .{ .r = 0, .g = 0, .b = 0, .a = 140 });
        bar.width *= @as(f32, @floatFromInt(w.xp)) / @as(f32, @floatFromInt(w.xp_next));
        frame.rect(bar, pink);
        for (0..@intCast(w.max_hp)) |i| self.icon(frame, if (i >= w.hp) c_bandaid_empty else c_bandaid, .{ .x = r.x + 6 + @as(f32, @floatFromInt(i)) * 24, .y = r.y + 8, .width = 30, .height = 30 }, false);
        var buffer: [32]u8 = undefined;
        self.center(frame, r.x + r.width / 2, r.y + 14, clockText(&buffer, w.time), 18, .bold, white);
        self.center(frame, r.x + r.width / 2, r.y + 38, std.fmt.bufPrint(&buffer, "Lv {d}", .{w.level}) catch "", 13, .semibold, gold);
        const stones = std.fmt.bufPrint(&buffer, "{d}", .{w.collected}) catch "";
        const font: ui.Font = .{ .size = 16, .weight = .bold };
        const sw = self.widths.get(stones, font);
        frame.labelFont(.{ .x = r.x + r.width - 14 - sw, .y = r.y + 12, .width = sw + 14, .height = 22 }, stones, white, font);
        self.icon(frame, c_stone + 1, .{ .x = r.x + r.width - 46 - sw, .y = r.y + 4, .width = 32, .height = 32 }, false);
        // The band so far, by the bottom left corner: who has yet to join
        // is a silhouette.
        for (0..member_count) |m| self.icon(frame, c_member + m * 2, .{ .x = r.x + 8 + @as(f32, @floatFromInt(m)) * 30, .y = r.y + r.height - 42, .width = 32, .height = 32 }, !(m == vocalist or w.joined(m)));
        if (w.banner_time > 0) {
            const k = @min(w.banner_time / 0.4, 1);
            const text = w.banner[0..w.banner_len];
            const banner_font: ui.Font = .{ .size = 20, .weight = .bold };
            const size: view.Size = .{ .width = self.widths.get(text, banner_font), .height = (view.Measurer{}).textSize(text, banner_font).height };
            const y = r.y + r.height * 0.24;
            const box: view.Rect = .{ .x = r.x + (r.width - size.width) / 2 - 16, .y = y - 8, .width = size.width + 32, .height = size.height + 16 };
            frame.roundedRect(box, box.height / 2, .{ .r = 14, .g = 12, .b = 28, .a = @intFromFloat(@round(191 * k)) });
            self.center(frame, r.x + r.width / 2, y, text, 20, .bold, fade(gold, night, k));
        }
    }

    fn drawTitle(self: *Mayoi, frame: *ui.Frame, r: view.Rect) void {
        dim(frame, r);
        const cx = r.x + r.width / 2;
        const cy = r.y + r.height / 2;
        const ticks: f64 = @floatFromInt(self.steps);
        for (0..member_count) |m| {
            const mf: f64 = @floatFromInt(m);
            const bob: f32 = @floatCast(@sin(ticks * 0.08 + mf * 1.2) * 3);
            const x = cx + (@as(f32, @floatCast(mf)) - 2) * 52 - 20;
            const f: usize = @intFromFloat(@mod(ticks / 20 + mf, 2));
            self.iconFlipped(frame, c_member + m * 2 + f, .{ .x = x, .y = cy - 128 + bob, .width = 40, .height = 40 }, m > 2);
            self.center(frame, x + 20, cy - 84, member_names[m], 11, .semibold, muted);
        }
        // The title, its letters spaced.
        const letters = "MAYOI";
        const font: ui.Font = .{ .size = 44, .weight = .bold };
        var widths: [letters.len]f32 = undefined;
        var total: f32 = 0;
        for (letters, 0..) |c, i| {
            widths[i] = self.widths.get(&.{c}, font);
            total += widths[i] + if (i + 1 < letters.len) @as(f32, 8) else 0;
        }
        var x = cx - total / 2;
        for (letters, 0..) |c, i| {
            frame.labelFont(.{ .x = x, .y = cy - 58, .width = widths[i] * 1.5 + 8, .height = 56 }, &.{c}, white, font);
            x += widths[i] + 8;
        }
        self.center(frame, cx, cy - 6, "迷子でもいい、前へ進め", 15, .regular, pink);
        self.center(frame, cx, cy + 18, "Hold out against stage fright, gather stones, and find your band.", 14, .regular, muted);
        if (@as(u64, @intFromFloat(ticks / 30)) % 2 == 0) self.center(frame, cx, cy + 60, "Click or press Space to start", 17, .bold, gold);
        self.center(frame, cx, r.y + r.height - 34, "A fan game · WASD or arrows walk · Esc pauses · M music · gamepads too", 12, .regular, muted);
    }

    /// Draws a bandmate, turned the other way if `flip`.
    fn iconFlipped(self: *Mayoi, frame: *ui.Frame, i: usize, dst: view.Rect, flip: bool) void {
        const icons = self.icons orelse return;
        const picture = icons.image(if (flip) Icons.mirrored else Icons.normal, i) orelse return;
        frame.image(dst, picture, .{ .sampling = .nearest }) catch {};
    }

    fn drawChoices(self: *Mayoi, frame: *ui.Frame, r: view.Rect) void {
        const w = &self.world;
        dim(frame, r);
        const n = w.choices_len;
        const cs = cards(n, r.width, r.height);
        var buffer: [48]u8 = undefined;
        if (n > 0) self.center(frame, r.x + r.width / 2, r.y + cs[0].y - 50, std.fmt.bufPrint(&buffer, "Level {d}!", .{w.level}) catch "", 28, .bold, gold);
        for (cs[0..n], 0..) |card, i| {
            const c: view.Rect = .{ .x = r.x + card.x, .y = r.y + card.y, .width = card.width, .height = card.height };
            const u = upgrades.get(w.choices[i]);
            frame.roundedRect(c, 12, .{ .r = 40, .g = 34, .b = 64, .a = 245 });
            if (i == self.pick) frame.strokeRect(c, 12, 2, ui.Color.rgb(gold));
            frame.labelFont(.{ .x = c.x + 10, .y = c.y + 6, .width = 20, .height = 18 }, std.fmt.bufPrint(&buffer, "{d}", .{i + 1}) catch "", muted, .{ .size = 12 });
            const cx = c.x + c.width / 2;
            var dst: view.Rect = .{ .x = cx - 24, .y = c.y + 14, .width = 48, .height = 48 };
            if (u.member) |m| if (!w.joined(m)) {
                // Who joins, with what they play.
                self.icon(frame, c_member + m * 2, .{ .x = cx - 44, .y = c.y + 14, .width = 48, .height = 48 }, false);
                dst = .{ .x = cx + 2, .y = c.y + 26, .width = 36, .height = 36 };
            };
            self.icon(frame, u.icon, dst, false);
            self.center(frame, cx, c.y + 70, u.name, 15, .bold, white);
            var lines = std.mem.splitScalar(u8, u.desc, '\n');
            var j: f32 = 0;
            while (lines.next()) |line| : (j += 1) self.center(frame, cx, c.y + 96 + j * 17, line, 12, .regular, muted);
            const lv = w.levels.get(w.choices[i]);
            const label = if (lv > 0) std.fmt.bufPrint(&buffer, "Level {d} → {d}", .{ lv, lv + 1 }) catch "" else "New";
            self.center(frame, cx, c.y + c.height - 26, label, 11, .semibold, gold);
        }
    }

    fn drawOver(self: *Mayoi, frame: *ui.Frame, r: view.Rect) void {
        const w = &self.world;
        dim(frame, r);
        const cx = r.x + r.width / 2;
        const cy = r.y + r.height / 2;
        var clock: [16]u8 = undefined;
        var buffer: [96]u8 = undefined;
        self.center(frame, cx, cy - 72, "It's okay to be lost.", 30, .bold, white);
        self.center(frame, cx, cy - 22, std.fmt.bufPrint(&buffer, "You held out {s} with a band of {d}, reached level {d},", .{ clockText(&clock, w.time), w.band_len + 1, w.level }) catch "", 15, .regular, muted);
        self.center(frame, cx, cy + 2, std.fmt.bufPrint(&buffer, "calmed {d} frights and collected {d} stones.", .{ w.calmed, w.collected }) catch "", 15, .regular, muted);
        if (w.over_time > 0.8) self.center(frame, cx, cy + 50, "Click or press Space to go on", 17, .bold, gold);
    }

    /// Draws the next picture of the world after this paint.
    fn requestRender(self: *Mayoi) void {
        if (self.queued) return;
        const host = self.host orelse return;
        const window = host.context.window orelse return;
        window.app.post(.{ .context = self, .call = render }) catch return;
        self.queued = true;
    }

    fn render(ptr: *anyopaque) void {
        const self: *Mayoi = @ptrCast(@alignCast(ptr));
        self.queued = false;
        const host = self.host orelse return;
        const window = host.context.window orelse return;
        const scene = self.next orelse return;
        const width: u32 = @intCast(scene.width);
        const height: u32 = @intCast(scene.height);
        if (self.image) |*image| if (image.width != width or image.height != height) {
            image.release(&host.context);
            image.deinit();
            self.image = null;
        };
        if (self.image == null) self.image = ui.PixelImage.init(self.allocator, width, height) catch return;
        const image = &self.image.?;
        var canvas: Canvas = .{ .pixels = image.pixels(), .width = scene.width, .height = scene.height };
        self.paintWorld(&canvas, scene);
        image.commit(&host.context) catch |err| return std.log.err("mayoi: {s}", .{@errorName(err)});
        self.shown = scene;
        window.invalidate();
    }

    /// Draws what the camera sees of the world, in its pixels: the street,
    /// the stones, the beat, the enemies and the band back to front, then
    /// the picks and the notes.
    fn paintWorld(self: *Mayoi, canvas: *Canvas, s: Scene) void {
        const w = &self.world;
        const sheet = &self.sheet;
        const a = s.alpha;
        for (0..s.height) |y| for (0..s.width) |x| {
            const wx = s.left + @as(i64, @intCast(x));
            const wy = s.top + @as(i64, @intCast(y));
            const color = sheet.get(tileAt(@divFloor(wx, cell), @divFloor(wy, cell)), @intCast(@mod(wx, cell)), @intCast(@mod(wy, cell)));
            const i = (y * s.width + x) * 4;
            canvas.pixels[i] = @truncate(color);
            canvas.pixels[i + 1] = @truncate(color >> 8);
            canvas.pixels[i + 2] = @truncate(color >> 16);
            canvas.pixels[i + 3] = 255;
        };
        const left: f64 = @floatFromInt(s.left);
        const top: f64 = @floatFromInt(s.top);
        const tomori = s.tomori;
        // A cell of 16 pixels whose bottom middle stands at v, raised dy.
        const Box = struct {
            fn x(v: Vec, l: f64) i64 {
                return @intFromFloat(@round(v.x - cell / 2 - l));
            }
            fn y(v: Vec, t: f64, dy: f64) i64 {
                return @intFromFloat(@round(v.y - cell + dy - t));
            }
        };
        if (w.beat_flash > 0) {
            const t = w.beat_flash / 0.4;
            const rr = w.beatRadius() * (1 - 0.4 * t);
            const fill: u32 = @as(u32, @intFromFloat(@round(t * 0.18 * 255))) << 24 | 0xa05ad6;
            const edge: u32 = @as(u32, @intFromFloat(@round(t * 255))) << 24 | 0xdcbeff;
            canvas.disc(tomori.x - left, tomori.y - 5 - top, rr, fill, edge);
        }
        const ticks: f64 = @floatFromInt(self.steps);
        for (w.stones.items, 0..) |st, i| {
            const c: usize = if (st.value >= 5) c_stone + 2 else if (st.value >= 2) c_stone + 1 else c_stone;
            const bob = @sin(ticks * 0.08 + @as(f64, @floatFromInt(i)));
            const at = st.prev.lerp(st.pos, a);
            canvas.sprite(sheet, c, Box.x(at, left), Box.y(at, top, 4 + bob), cell, .{});
        }
        for (w.puffs.items) |p| {
            const puff_frame: usize = @intFromFloat(@min(p.t / 0.32 * 3, 2));
            canvas.sprite(sheet, c_puff + puff_frame, Box.x(p.pos, left), Box.y(p.pos, top, 4), cell, .{ .alpha = @floatCast(1 - p.t / 0.32) });
        }
        // The band and the enemies, by their feet, back to front.
        const Figure = struct { at: Vec, enemy: ?usize, member: usize = 0 };
        var figures: std.ArrayList(Figure) = .empty;
        defer figures.deinit(self.allocator);
        const walking = w.move.len() > 0.05 and w.state == .playing;
        if (w.state != .title) {
            figures.append(self.allocator, .{ .at = tomori, .enemy = null, .member = vocalist }) catch {};
            for (w.band[0..w.band_len], 0..) |m, i| figures.append(self.allocator, .{ .at = w.follower(i), .enemy = null, .member = m }) catch {};
        }
        for (w.enemies.items, 0..) |e, i| figures.append(self.allocator, .{ .at = e.prev.lerp(e.pos, a), .enemy = i }) catch {};
        std.mem.sort(Figure, figures.items, {}, struct {
            fn less(_: void, x: Figure, y: Figure) bool {
                return x.at.y < y.at.y;
            }
        }.less);
        for (figures.items) |f| {
            const enemy_index = f.enemy orelse {
                // Blinking, unhurtable.
                if (f.member == vocalist and w.hurt > 0 and @as(u64, @intFromFloat(w.hurt * 14)) % 2 == 0) continue;
                const frame: usize = if (walking) @as(usize, @intFromFloat(w.walked / 7 + @as(f64, @floatFromInt(f.member)))) % 2 else 0;
                var turned = w.facing_left;
                if (f.member != vocalist) turned = f.at.x > tomori.x + 2 or (f.at.x >= tomori.x - 2 and w.facing_left);
                canvas.sprite(sheet, c_member + f.member * 2 + frame, Box.x(f.at, left), Box.y(f.at, top, 1), cell, .{ .flip = turned });
                continue;
            };
            const e = w.enemies.items[enemy_index];
            const c: usize, const speed: f64 = switch (e.kind) {
                .static => .{ c_static, 6 },
                .crow => .{ c_crow, 9 },
                .shadow => .{ c_shadow, 3 },
            };
            const frame: usize = @as(usize, @intFromFloat(e.phase * speed)) % 2;
            canvas.sprite(sheet, c + frame, Box.x(f.at, left), Box.y(f.at, top, 1), cell, .{ .flip = f.at.x > tomori.x, .tint = if (e.flash > 0) 0xff8caa else 0xffffff });
        }
        const n = w.levels.get(.picks);
        for (0..n) |i| {
            const b = World.pickPos(i, n, tomori, w.pick_angle);
            canvas.turned(sheet, c_pick, b.x - left, b.y - 1 - top, 12, w.pick_angle + @as(f64, @floatFromInt(i)) * 2 * std.math.pi / @as(f64, @floatFromInt(n)));
        }
        for (w.sung.items, 0..) |note, i| {
            const at = note.prev.lerp(note.pos, a);
            const wob = @sin(ticks * 0.3 + @as(f64, @floatFromInt(i))) * 1.5;
            canvas.sprite(sheet, c_note, @intFromFloat(@round(at.x - 7 - left)), @intFromFloat(@round(at.y - 9 + wob - top)), 14, .{});
        }
    }
};

const App = struct {
    mayoi: Mayoi,
    loop: game.View = undefined,

    fn bind(self: *App) void {
        self.loop = game.View.init(game.Game.bind(&self.mayoi));
    }
    fn build(self: *App, v: *view.View) anyerror!void {
        try self.loop.build(v, .{ .grow = 1, .self_align = .stretch, .name = "Mayoi", .background = night });
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app_state = try allocator.create(App);
    defer allocator.destroy(app_state);
    app_state.* = .{ .mayoi = .init(allocator, zio.random.int(u64)) };
    defer app_state.mayoi.deinit();
    app_state.bind();
    var storage: view.Storage(16, 256) = .{};
    var host = view.Host.init(app_state, App.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0) }, .background = night });
    var timer = view_timer.Timer.init(&host);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try audio.Engine.init(allocator, .{ .app = app });
    defer engine.deinit();
    var sounds = try Sounds.init(allocator, engine);
    defer sounds.deinit();
    app_state.mayoi.sounds = &sounds;
    const engine_text = try text_layout.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine_text.close() catch {};
    app_state.mayoi.widths.engine = engine_text;

    const window = try app.createWindow(.{ .title = "Mayoi", .width = 960, .height = 640, .min_width = 480, .min_height = 360 });
    try host.attach(window);
    try timer.attach(app, allocator);
    const icons = try allocator.create(Icons);
    defer allocator.destroy(icons);
    icons.* = .init(&app_state.mayoi.sheet);
    try icons.upload(&host.context);
    app_state.mayoi.icons = icons;
    app_state.mayoi.host = &host;

    window.show();
    try app.run();
    icons.release(&host.context);
    if (app_state.mayoi.image) |*image| image.release(&host.context);
    app_state.mayoi.host = null;
    app_state.mayoi.icons = null;
    app_state.mayoi.sounds = null;
    app_state.mayoi.widths.engine = null;
    try timer.close();
}

/// A world in play, without enemies coming for a while.
fn inPlay(allocator: std.mem.Allocator) World {
    var w: World = .init(allocator, 1);
    w.reset();
    w.spawn_timer = 1e9;
    w.wave_timer = 1e9;
    return w;
}

fn run(w: *World, seconds: f64) void {
    for (0..@intFromFloat(seconds * game.rate)) |_| w.step(step_time);
}

test "Tomori sings on her own at an enemy in reach and calms it, which leaves a stone she picks up" {
    var w = inPlay(std.testing.allocator);
    defer w.deinit();
    w.add(.static, .{ .x = 60 });
    run(&w, 2);
    try std.testing.expectEqual(@as(u32, 1), w.calmed);
    try std.testing.expectEqual(@as(usize, 0), w.enemies.items.len);
    try std.testing.expectEqual(@as(usize, 1), w.stones.items.len);
    w.move = .{ .x = 1 };
    run(&w, 1);
    try std.testing.expectEqual(@as(u32, 1), w.xp);
    try std.testing.expectEqual(@as(u32, 1), w.collected);
    try std.testing.expectEqual(@as(usize, 0), w.stones.items.len);
}

test "enough experience offers three upgrades, a bandmate among them, which wait for a choice" {
    var w = inPlay(std.testing.allocator);
    defer w.deinit();
    try w.stones.append(w.allocator, .{ .pos = .{ .y = -4 }, .prev = .{ .y = -4 }, .value = 5 });
    w.step(step_time);
    try std.testing.expect(w.state == .choosing and w.level == 2 and w.choices_len == 3);
    const before = w.time;
    run(&w, 1);
    try std.testing.expectEqual(before, w.time);
    var bandmate = false;
    for (w.choices[0..w.choices_len]) |u| bandmate = bandmate or upgrades.get(u).member != null;
    try std.testing.expect(bandmate);
    const u = w.choices[0];
    w.choose(0);
    try std.testing.expect(w.state == .playing and w.levels.get(u) == 1);
}

test "upgrades: bandmates join once and follow, and the picks and the beat calm what comes near" {
    var w = inPlay(std.testing.allocator);
    defer w.deinit();
    for ([_]Upgrade{ .harmony, .picks, .drums, .bandaid, .harmony }) |u| {
        w.state = .choosing;
        w.choices[0] = u;
        w.choices_len = 1;
        w.choose(0);
    }
    try std.testing.expect(w.notes == 3 and w.levels.get(.picks) == 1 and w.max_hp == 6 and w.hp == 6);
    try std.testing.expectEqualSlices(usize, &.{ guitarist, lead, drummer }, w.band[0..w.band_len]);
    w.move = .{ .x = 1 };
    run(&w, 2);
    const f = w.follower(0);
    try std.testing.expect(f.x < w.pos.x and f.x >= w.pos.x - 30);
    w.move = .{};
    w.beat_timer = 0.5;
    w.damage = 0;
    w.add(.static, w.pos.add(.{ .x = 30, .y = -5 }));
    w.add(.crow, w.pos.add(.{ .x = -30, .y = 20 }));
    run(&w, 3);
    try std.testing.expectEqual(@as(u32, 2), w.calmed);
}

test "an enemy reaching Tomori takes a band-aid; without band-aids, the game is over" {
    var w = inPlay(std.testing.allocator);
    defer w.deinit();
    w.damage = 0;
    w.add(.shadow, .{ .x = 3 });
    run(&w, 0.1);
    try std.testing.expect(w.hp == 4 and w.hurt > 0);
    w.hp = 1;
    run(&w, 3);
    try std.testing.expectEqual(State.over, w.state);
}

test "enemies come from beyond the view, more as time goes on, and stay apart" {
    var w: World = .init(std.testing.allocator, 2);
    defer w.deinit();
    w.reset();
    w.damage = 0;
    w.hurt = 1e9;
    w.spawn(30);
    try std.testing.expect(w.enemies.items.len >= 30);
    for (w.enemies.items) |e| {
        const d = e.pos.sub(w.pos);
        try std.testing.expect(!(@abs(d.x) < w.view.x and @abs(d.y) < w.view.y));
    }
    run(&w, 5);
    for (w.enemies.items, 0..) |a, i| for (w.enemies.items[i + 1 ..]) |b| try std.testing.expect(a.pos.sub(b.pos).len() >= 2);
}

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};

test "the view starts the game with a key, walks Tomori with the keys, and waits without the keyboard" {
    const app_state = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = .{ .mayoi = .init(std.testing.allocator, 3) };
    defer app_state.mayoi.deinit();
    app_state.bind();
    var storage: view.Storage(16, 256) = .{};
    var h = view.Harness.init(app_state, App.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 960, .height = 640 } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    const step = std.time.ns_per_s / game.rate;
    try h.advance(step);
    const g = &app_state.mayoi;
    _ = try h.key(.{ .key = .space });
    _ = try h.keyUp(.{ .key = .space });
    for (0..3) |_| try h.advance(step);
    try std.testing.expect(g.world.state == .playing and g.sounding);
    // Paused, the music pauses too.
    _ = try h.key(.{ .key = .escape });
    _ = try h.keyUp(.{ .key = .escape });
    for (0..3) |_| try h.advance(step);
    try std.testing.expect(g.paused and !g.sounding);
    _ = try h.key(.{ .key = .escape });
    _ = try h.keyUp(.{ .key = .escape });
    for (0..3) |_| try h.advance(step);
    try std.testing.expect(!g.paused and g.sounding);
    const x = g.world.pos.x;
    _ = try h.key(.{ .key = .unknown, .physical = .d });
    for (0..12) |_| try h.advance(step);
    try std.testing.expect(g.world.pos.x > x and !g.world.facing_left);
    _ = try h.keyUp(.{ .key = .unknown, .physical = .d });
    try h.windowFocus(false);
    for (0..3) |_| try h.advance(step);
    const before = g.world.time;
    for (0..3) |_| try h.advance(step);
    try std.testing.expect(g.world.time == before and g.frozen and !g.sounding);
}

test "the tune plays its parts as the band grows" {
    const tune = try Tune.create(std.testing.allocator);
    defer tune.destroy();
    var buffer: [2 * 4096]f32 = undefined;
    const d = tune.decoder();
    try d.setPosition(@intFromFloat(bar_len * tune_rate));
    const n = try d.read(&buffer);
    try std.testing.expectEqual(buffer.len, n);
    var loud: f32 = 0;
    for (buffer) |s| loud = @max(loud, @abs(s));
    try std.testing.expect(loud > 0.05 and loud <= 1.2);
    try d.setPosition(Tune.frames());
    try std.testing.expectEqual(@as(usize, 0), try d.read(&buffer));
}

test "the art: sprites blit over the street, flipped and tinted" {
    var sheet: Sheet = .{};
    sheet.draw();
    // Tomori's hair is at the top of her cell; her stepping frame differs.
    try std.testing.expect(sheet.get(c_member, 6, 1) >> 24 == 0xff);
    var differs = false;
    for (0..cell) |y| for (0..cell) |x| {
        differs = differs or sheet.get(c_member, x, y) != sheet.get(c_member + 1, x, y);
    };
    try std.testing.expect(differs);
    var pixels: [32 * 32 * 4]u8 = @splat(0);
    var canvas: Canvas = .{ .pixels = &pixels, .width = 32, .height = 32 };
    canvas.sprite(&sheet, c_crow, 0, 0, cell, .{ .flip = true, .tint = 0xff8caa });
    var drawn: usize = 0;
    var i: usize = 3;
    while (i < pixels.len) : (i += 4) drawn += @intFromBool(pixels[i] != 0);
    try std.testing.expect(drawn > 20);
    try std.testing.expect(tileAt(3, 4) == tileAt(3, 4));
    // The icons and the world's picture fit the renderers' 32.
    var icons: usize = 0;
    for (0..3) |variant| for (0..64) |j| {
        icons += @intFromBool(Icons.used(variant, j));
    };
    try std.testing.expect(icons + 1 <= 32);
}
