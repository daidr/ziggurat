//! On-screen piano: click a key or type on the computer keyboard (A S D F G
//! H J K L ; for white keys, W E T Y U O P for black keys). Every note is
//! synthesized in code into an `audio.Sound` once per waveform; a press
//! creates a paused player, sets its speed for the octave, plays it and
//! releases the handle so the player frees itself when the note ends. The
//! engine mixes on its own threads; everything here runs on the main thread
//! and the engine's output callback arrives through `App.post`.
//!
//! Run with `zig build run-piano`. Without an audio device, notes still play
//! on time, unheard, and the window says why.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");
const audio = @import("ziggurat_audio");

const ms = std.time.ns_per_ms;
const rate = audio.sample_rate;
const note_seconds = 1.5;
/// How long a pressed key stays lit.
const lit_ns = 180 * ms;

const Key = struct { name: []const u8, black: bool, code: z.KeyCode };
/// C4 to E5 in semitones, with the computer key that plays each.
const keys = [_]Key{
    .{ .name = "C4", .black = false, .code = .a },         .{ .name = "C#4", .black = true, .code = .w },
    .{ .name = "D4", .black = false, .code = .s },         .{ .name = "D#4", .black = true, .code = .e },
    .{ .name = "E4", .black = false, .code = .d },         .{ .name = "F4", .black = false, .code = .f },
    .{ .name = "F#4", .black = true, .code = .t },         .{ .name = "G4", .black = false, .code = .g },
    .{ .name = "G#4", .black = true, .code = .y },         .{ .name = "A4", .black = false, .code = .h },
    .{ .name = "A#4", .black = true, .code = .u },         .{ .name = "B4", .black = false, .code = .j },
    .{ .name = "C5", .black = false, .code = .k },         .{ .name = "C#5", .black = true, .code = .o },
    .{ .name = "D5", .black = false, .code = .l },         .{ .name = "D#5", .black = true, .code = .p },
    .{ .name = "E5", .black = false, .code = .semicolon },
};
const white_count = blk: {
    var count: usize = 0;
    for (keys) |key| count += @intFromBool(!key.black);
    break :blk count;
};

const Waveform = enum { sine, triangle, square, sawtooth };
const Octave = enum { low, middle, high };

fn frequency(note: usize) f64 {
    return 261.6256 * std.math.pow(f64, 2, @as(f64, @floatFromInt(note)) / 12);
}

/// One note: the waveform under a short attack and an exponential decay.
fn synthesize(out: []f32, waveform: Waveform, hz: f64) void {
    const fade_frames: f64 = rate * 0.02;
    for (out, 0..) |*sample, i| {
        const t = @as(f64, @floatFromInt(i)) / rate;
        const phase = @mod(t * hz, 1.0);
        const wave = switch (waveform) {
            .sine => @sin(2 * std.math.pi * phase),
            .triangle => 1 - 4 * @abs(phase - 0.5),
            .square => (if (phase < 0.5) @as(f64, 1) else -1) * 0.45,
            .sawtooth => (2 * phase - 1) * 0.55,
        };
        const attack = @min(1, t / 0.005);
        const tail = @min(1, @as(f64, @floatFromInt(out.len - i)) / fade_frames);
        sample.* = @floatCast(0.3 * wave * attack * tail * @exp(-3 * t));
    }
}

const Piano = struct {
    host: view.Host = undefined,
    allocator: std.mem.Allocator,
    engine: *audio.Engine,
    window: ?z.Window = null,
    sounds: [keys.len]?*audio.Sound = @splat(null),
    waveform: Waveform = .sine,
    octave: Octave = .middle,
    volume: f64 = 0.8,
    /// Host time until which each key is drawn pressed.
    lit_until: [keys.len]u64 = @splat(0),
    /// Time of the current pass, for paint.
    now: u64 = 0,
    last_note: ?usize = null,
    last_error: ?anyerror = null,
    keyboard_bounds: view.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// The Host's own input routing, which `onInput` forwards to.
    host_input: ?*const fn (*anyopaque, *ui.Context, z.Event) bool = null,

    /// Synthesize every note for the current waveform. Players still
    /// sounding keep the previous sounds alive until they end.
    fn synthesizeAll(self: *Piano) !void {
        const buffer = try self.allocator.alloc(f32, @intFromFloat(rate * note_seconds));
        defer self.allocator.free(buffer);
        var fresh: [keys.len]?*audio.Sound = @splat(null);
        errdefer for (fresh) |sound| if (sound) |s| s.release();
        for (&fresh, 0..) |*sound, note| {
            synthesize(buffer, self.waveform, frequency(note));
            sound.* = try audio.Sound.fromSamples(self.allocator, rate, 1, buffer);
        }
        self.releaseSounds();
        self.sounds = fresh;
    }

    fn releaseSounds(self: *Piano) void {
        for (&self.sounds) |*sound| if (sound.*) |s| {
            s.release();
            sound.* = null;
        };
    }

    fn press(self: *Piano, note: usize, now: u64) void {
        self.last_note = note;
        self.lit_until[note] = now + lit_ns;
        const sound = self.sounds[note] orelse return;
        const player = self.engine.createPlayer(sound) catch |err| {
            self.last_error = err;
            return;
        };
        player.setSpeed(switch (self.octave) {
            .low => 0.5,
            .middle => 1,
            .high => 2,
        });
        player.play();
        // The engine now owns the player; it frees itself at the end.
        player.release();
    }

    fn build(self: *Piano, v: *view.View) anyerror!void {
        self.now = v.time();
        try v.text("Piano", .{ .font = view.Font.heading3 });
        try v.row(.{ .gap = 16, .alignment = .center, .self_align = .stretch });
        try v.segmented(.{ .name = "Waveform" });
        var changed = try v.segment(Waveform, &self.waveform, .sine, "Sine", .{});
        changed = try v.segment(Waveform, &self.waveform, .triangle, "Triangle", .{}) or changed;
        changed = try v.segment(Waveform, &self.waveform, .square, "Square", .{}) or changed;
        changed = try v.segment(Waveform, &self.waveform, .sawtooth, "Saw", .{}) or changed;
        try v.end();
        if (changed) self.synthesizeAll() catch |err| {
            self.last_error = err;
        };
        try v.segmented(.{ .name = "Octave" });
        _ = try v.segment(Octave, &self.octave, .low, "Low", .{});
        _ = try v.segment(Octave, &self.octave, .middle, "Middle", .{});
        _ = try v.segment(Octave, &self.octave, .high, "High", .{});
        try v.end();
        try v.end();

        try v.row(.{ .gap = 12, .alignment = .center, .self_align = .stretch });
        try v.text("Volume", .{});
        if (try v.slider(&self.volume, .{ .minimum = 0, .maximum = 1, .step = 0.05 }, .{ .grow = 1, .name = "Volume" })) self.engine.setVolume(self.volume);
        try v.textf("{d:.0}%", .{self.volume * 100}, .{ .width = 48 });
        try v.end();

        try v.embed(.{ .context = self, .measure = measure, .place = place, .paint = paint, .input = input }, .{ .grow = 1, .self_align = .stretch, .key = 1 });

        // Keep the timer armed only while some key is still lit.
        var next: ?u64 = null;
        for (self.lit_until) |until| if (until > self.now) {
            next = if (next) |n| @min(n, until) else until;
        };
        if (next) |deadline| v.wakeAt(deadline);

        if (self.engine.outputError()) |err| {
            try v.textf("No audio output ({s}); notes play silently and the device is retried.", .{@errorName(err)}, .{ .color = 0xa8530f, .key = 2 });
        } else if (self.last_note) |note| {
            try v.textf("Last note: {s} ({d:.1} Hz)", .{ keys[note].name, frequency(note) * @as(f64, switch (self.octave) {
                .low => 0.5,
                .middle => 1,
                .high => 2,
            }) }, .{ .color = 0x536475, .key = 3 });
        } else try v.text("Click a key, or type A S D F G H J K L ; and W E T Y U O P.", .{ .color = 0x536475, .key = 4 });
        if (self.last_error) |err| try v.textf("Error: {s}", .{@errorName(err)}, .{ .color = 0xa8530f, .key = 5 });
    }

    fn measure(_: *anyopaque, _: ui.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 300, .height = 120 }, .preferred = .{ .width = 640, .height = 200 } };
    }
    fn place(context: *anyopaque, _: u64, bounds: view.Rect) void {
        const self: *Piano = @ptrCast(@alignCast(context));
        self.keyboard_bounds = bounds;
    }

    /// Key rectangles relative to the keyboard's origin.
    fn keyRect(note: usize, width: f32, height: f32) view.Rect {
        const white = width / @as(f32, @floatFromInt(white_count));
        var whites_before: f32 = 0;
        for (keys[0..note]) |key| whites_before += @floatFromInt(@intFromBool(!key.black));
        if (!keys[note].black) return .{ .x = whites_before * white, .y = 0, .width = white, .height = height };
        return .{ .x = whites_before * white - white * 0.3, .y = 0, .width = white * 0.6, .height = height * 0.6 };
    }
    fn noteAt(self: *const Piano, point: view.Point) ?usize {
        const b = self.keyboard_bounds;
        // Black keys sit on top, so they win.
        for ([_]bool{ true, false }) |black| for (keys, 0..) |key, note| {
            if (key.black != black) continue;
            const r = keyRect(note, b.width, b.height);
            if (point.x >= r.x and point.x < r.x + r.width and point.y >= r.y and point.y < r.y + r.height) return note;
        };
        return null;
    }

    fn paint(context: *anyopaque, frame: *ui.Frame, _: u64, bounds: view.Rect) anyerror!void {
        const self: *Piano = @ptrCast(@alignCast(context));
        const palette = frame.currentTheme().palette;
        for ([_]bool{ false, true }) |black| for (keys, 0..) |key, note| {
            if (key.black != black) continue;
            var r = keyRect(note, bounds.width, bounds.height);
            r.x += bounds.x;
            r.y += bounds.y;
            const lit = self.lit_until[note] > self.now;
            const fill: u32 = if (lit) palette.accent else if (black) 0x1e252c else 0xfbfbf8;
            frame.roundedRect(r, 4, ui.Color.rgb(palette.border));
            frame.roundedRect(.{ .x = r.x + 1, .y = r.y + 1, .width = r.width - 2, .height = r.height - 2 }, 3, ui.Color.rgb(fill));
            const text: u32 = if (lit) palette.on_accent else if (black) 0xd8dde2 else palette.text;
            const caption = r.y + r.height - 28;
            frame.label(.{ .x = r.x + 4, .y = caption, .width = r.width - 8, .height = 24 }, keyLabel(key.code), text);
        };
    }
    fn keyLabel(code: z.KeyCode) []const u8 {
        return if (code == .semicolon) ";" else @tagName(code);
    }

    fn input(context: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *Piano = @ptrCast(@alignCast(context));
        switch (event) {
            .pointer_down => |pressed| {
                const note = self.noteAt(pressed.position) orelse return false;
                self.press(note, self.host.time());
                return true;
            },
            else => return false,
        }
    }

    /// Note keys play wherever focus is; everything else goes on to the
    /// Host's routing for the controls.
    fn onInput(ptr: *anyopaque, context: *ui.Context, event: z.Event) bool {
        const host: *view.Host = @ptrCast(@alignCast(ptr));
        const self: *Piano = @fieldParentPtr("host", host);
        if (event == .key_input) {
            const key = event.key_input;
            const m = key.modifiers;
            if (!(m.control or m.alt or m.super)) for (keys, 0..) |candidate, note| {
                if (candidate.code != key.key) continue;
                if (!key.repeat) {
                    self.press(note, host.time());
                    if (self.window) |window| window.invalidate();
                }
                return true;
            };
        }
        const forward = self.host_input orelse return false;
        return forward(ptr, context, event);
    }

    /// Output errors change on the engine's threads and arrive here through
    /// `App.post`, on the main thread.
    fn outputChanged(context: *anyopaque, _: *audio.Engine) void {
        const self: *Piano = @ptrCast(@alignCast(context));
        if (self.window) |window| window.invalidate();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    // The engine frees on its decoding thread, so its allocator must be
    // thread-safe; DebugAllocator is by default.
    const allocator = gpa.allocator();

    const app = try z.App.init(allocator);
    defer app.deinit();

    var piano: Piano = .{ .allocator = allocator, .engine = undefined };
    piano.engine = try audio.Engine.init(allocator, .{ .app = app, .on_output = .{ .context = &piano, .call = Piano.outputChanged } });
    // Runs before app.deinit: stops the mixing threads and frees the players.
    defer piano.engine.deinit();
    defer piano.releaseSounds();
    piano.engine.setVolume(piano.volume);
    try piano.synthesizeAll();

    var storage: view.Storage(64, 2048) = .{};
    piano.host = view.Host.init(&piano, Piano.build, storage.buffers(), .{});
    var timer = view_timer.Timer.init(&piano.host);

    const window = try app.createWindow(.{ .title = "Ziggurat - Piano", .width = 760, .height = 420, .min_width = 480, .min_height = 320 });
    piano.window = window;
    try piano.host.attach(window);
    // Chain the Host's input routing so note keys play regardless of focus.
    piano.host_input = piano.host.context.on_input;
    piano.host.context.on_input = Piano.onInput;
    try timer.attach(app, allocator);

    window.show();
    try app.run();
    try timer.close();
}

test "keys synthesize, play and light up headlessly" {
    const engine = try audio.Engine.init(std.testing.allocator, .{ .output = .manual });
    defer engine.deinit();
    var piano: Piano = .{ .allocator = std.testing.allocator, .engine = engine };
    defer piano.releaseSounds();
    try piano.synthesizeAll();
    var storage: view.Storage(64, 2048) = .{};
    var h = view.Harness.init(&piano, Piano.build, storage.buffers(), .{});
    try h.render();
    try h.click(.{ .text = "Square" });
    try std.testing.expectEqual(Waveform.square, piano.waveform);
    piano.press(9, piano.now);
    try h.render();
    try std.testing.expect(h.deadline() != null);
    try h.advance(lit_ns + 1);
    try std.testing.expectEqual(@as(?u64, null), h.deadline());
    var mix: [2 * audio.period_frames]f32 = undefined;
    try std.testing.expect(engine.render(&mix));
}
