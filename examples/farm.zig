//! A small farm to till and water: walk with WASD or the arrows (keys by
//! position, so the same keys on any layout) or a gamepad's left stick,
//! till the grass under you with Space or the pad's south button, water the
//! soil with E or the east button, and watered soil grows a crop in a few
//! seconds. `ziggurat_game` runs the world in fixed steps of 60 a second
//! whatever the display's rate, draws it every frame between its last two
//! steps, and looks at it through a camera that follows the farmer, three
//! times as large, on whole screen pixels. The farm pauses while it lacks
//! the keyboard.
//!
//! Run with `zig build run-farm`.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");
const game = @import("ziggurat_game");
const gamepad = game.gamepad;

const columns = 24;
const rows = 16;
const tile: f32 = 16;
const speed: f32 = 1.5;
/// Steps a watered tile takes to grow a crop: three seconds.
const grow_steps = 3 * game.rate;

const Tile = enum { grass, soil, watered, crop };

const Farm = struct {
    tiles: [rows][columns]Tile = @splat(@splat(.grass)),
    /// Steps since each tile was watered.
    growth: [rows][columns]u32 = @splat(@splat(0)),
    x: f32 = columns * tile / 2,
    y: f32 = rows * tile / 2,
    /// Where the farmer was a step before, to draw between the two.
    px: f32 = columns * tile / 2,
    py: f32 = rows * tile / 2,
    harvest: u32 = 0,
    steps: u64 = 0,
    paused: bool = true,
    pads: gamepad.Gamepads = .{},
    last_pad: gamepad.State = .{},

    pub fn update(self: *Farm, in: *const game.Input) void {
        self.paused = !in.focused();
        if (self.paused) return;
        self.steps += 1;
        self.px = self.x;
        self.py = self.y;

        var dx: f32 = 0;
        var dy: f32 = 0;
        if (in.down(.a) or in.down(.left)) dx -= 1;
        if (in.down(.d) or in.down(.right)) dx += 1;
        if (in.down(.w) or in.down(.up)) dy -= 1;
        if (in.down(.s) or in.down(.down)) dy += 1;
        var till = in.pressed(.space);
        var water = in.pressed(.e);
        var buffer: [gamepad.max_pads]gamepad.Pad = undefined;
        const pads = self.pads.pads(self.steps * std.time.ns_per_s / game.rate, &buffer);
        if (pads.len > 0) {
            const s = pads[0].state();
            const stick = s.leftStick();
            dx += stick.x;
            dy += stick.y;
            if (s.pressed(.left)) dx -= 1;
            if (s.pressed(.right)) dx += 1;
            if (s.pressed(.up)) dy -= 1;
            if (s.pressed(.down)) dy += 1;
            till = till or s.justPressed(self.last_pad, .south);
            water = water or s.justPressed(self.last_pad, .east);
            self.last_pad = s;
        }
        const length = @sqrt(dx * dx + dy * dy);
        if (length > 1) {
            dx /= length;
            dy /= length;
        }
        self.x = std.math.clamp(self.x + dx * speed, tile / 2, columns * tile - tile / 2);
        self.y = std.math.clamp(self.y + dy * speed, tile / 2, rows * tile - tile / 2);

        const here = self.under();
        const t = &self.tiles[here.row][here.col];
        if (till and t.* == .grass) t.* = .soil;
        if (water and t.* == .soil) {
            t.* = .watered;
            self.growth[here.row][here.col] = 0;
        }
        for (&self.tiles, &self.growth) |*line, *ages| for (line, ages) |*cell, *age| {
            if (cell.* != .watered) continue;
            age.* += 1;
            if (age.* >= grow_steps) cell.* = .crop;
        };
        // Walking onto a crop harvests it.
        if (t.* == .crop) {
            t.* = .soil;
            self.harvest += 1;
        }
    }

    fn under(self: *const Farm) struct { row: usize, col: usize } {
        const col: usize = @intFromFloat(std.math.clamp(@floor(self.x / tile), 0, columns - 1));
        const row: usize = @intFromFloat(std.math.clamp(@floor(self.y / tile), 0, rows - 1));
        return .{ .row = row, .col = col };
    }

    pub fn draw(self: *Farm, frame: *ui.Frame, bounds: view.Rect, alpha: f64) !void {
        frame.rect(bounds, 0x2d4a2b);
        // Between the last two steps, as far as the frame is into the next.
        const a: f32 = @floatCast(alpha);
        const at: view.Point = .{ .x = self.px + (self.x - self.px) * a, .y = self.py + (self.y - self.py) * a };
        const camera: game.Camera = .{ .x = at.x, .y = at.y, .zoom = 3 };
        try camera.draw(frame, bounds, Scene{ .farm = self, .at = at }, Scene.paint);
        frame.label(.{ .x = bounds.x + 12, .y = bounds.y + 8, .width = 360, .height = 24 }, if (self.paused) "Paused: click the farm to play" else "Space tills, E waters, walk onto crops", 0xffffff);
        var buffer: [48]u8 = undefined;
        const counts = std.fmt.bufPrint(&buffer, "Harvest: {d}", .{self.harvest}) catch "";
        frame.label(.{ .x = bounds.x + bounds.width - 140, .y = bounds.y + 8, .width = 128, .height = 24 }, counts, 0xffffff);
    }
};

const Scene = struct {
    farm: *const Farm,
    at: view.Point,

    fn paint(self: Scene, lens: *game.Lens) anyerror!void {
        for (self.farm.tiles, 0..) |line, row| for (line, 0..) |cell, col| {
            const box: view.Rect = .{ .x = @as(f32, @floatFromInt(col)) * tile, .y = @as(f32, @floatFromInt(row)) * tile, .width = tile, .height = tile };
            lens.rect(box, switch (cell) {
                .grass => if ((row + col) % 2 == 0) 0x6fae4f else 0x67a548,
                .soil => 0x8a5a36,
                .watered, .crop => 0x5b3a22,
            });
            if (cell == .crop) {
                lens.roundedRect(.{ .x = box.x + 4, .y = box.y + 3, .width = 8, .height = 10 }, 3, ui.Color.rgb(0xf2c443));
                lens.rect(.{ .x = box.x + 7, .y = box.y + 1, .width = 2, .height = 4 }, 0x3f8f3a);
            }
        };
        // The farmer.
        lens.roundedRect(.{ .x = self.at.x - 5, .y = self.at.y - 7, .width = 10, .height = 14 }, 3, ui.Color.rgb(0x2a6fd4));
        lens.roundedRect(.{ .x = self.at.x - 4, .y = self.at.y - 11, .width = 8, .height = 7 }, 3.5, ui.Color.rgb(0xf0c8a0));
    }
};

const App = struct {
    farm: Farm = .{},
    loop: game.View = undefined,

    fn bind(self: *App) void {
        self.loop = game.View.init(game.Game.bind(&self.farm));
    }
    fn build(self: *App, v: *view.View) anyerror!void {
        try self.loop.build(v, .{ .grow = 1, .self_align = .stretch, .name = "Farm" });
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var app_state: App = .{};
    app_state.bind();
    defer app_state.farm.pads.deinit();
    var storage: view.Storage(16, 256) = .{};
    var host = view.Host.init(&app_state, App.build, storage.buffers(), .{});
    var timer = view_timer.Timer.init(&host);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Ziggurat - Farm", .width = 800, .height = 520, .min_width = 320, .min_height = 240 });
    try host.attach(window);
    try timer.attach(app, allocator);
    window.show();
    try app.run();
    try timer.close();
}

const step = std.time.ns_per_s / game.rate;

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};

test "the farmer walks, tills, waters and harvests" {
    var app_state: App = .{};
    app_state.bind();
    defer app_state.farm.pads.deinit();
    var storage: view.Storage(16, 256) = .{};
    var h = view.Harness.init(&app_state, App.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    try h.advance(step);
    const farm = &app_state.farm;
    try std.testing.expect(!farm.paused);

    const start = farm.x;
    _ = try h.key(.{ .key = .unknown, .physical = .d });
    for (0..10) |_| try h.advance(step);
    _ = try h.keyUp(.{ .key = .unknown, .physical = .d });
    try std.testing.expectApproxEqAbs(start + 10 * speed, farm.x, 0.01);

    const here = farm.under();
    _ = try h.key(.{ .key = .space });
    try h.advance(step);
    try std.testing.expectEqual(Tile.soil, farm.tiles[here.row][here.col]);
    _ = try h.key(.{ .key = .e });
    try h.advance(step);
    try std.testing.expectEqual(Tile.watered, farm.tiles[here.row][here.col]);
    // A crop grows under the farmer and is harvested at once.
    for (0..grow_steps) |_| try h.advance(step);
    try std.testing.expectEqual(@as(u32, 1), farm.harvest);
    try std.testing.expectEqual(Tile.soil, farm.tiles[here.row][here.col]);

    // Without the keyboard the farm pauses.
    try h.windowFocus(false);
    const steps = farm.steps;
    try h.advance(step);
    try std.testing.expect(farm.paused);
    try std.testing.expectEqual(steps, farm.steps);
}
