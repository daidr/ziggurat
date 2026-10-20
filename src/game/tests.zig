const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const game = @import("root.zig");

const testing = std.testing;
const Harness = view.Harness;
const Rect = view.Rect;
const step = std.time.ns_per_s / 60;

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};
const Storage = view.Storage(64, 1024);

const Walker = struct {
    x: f32 = 0,
    updates: usize = 0,
    jumps: usize = 0,
    landed: usize = 0,
    clicks: usize = 0,
    focused: bool = false,
    wheel: f32 = 0,
    alpha: f64 = 0,
    draws: usize = 0,

    pub fn update(self: *Walker, in: *const game.Input) void {
        self.updates += 1;
        self.focused = in.focused();
        if (in.down(.d)) self.x += 2;
        if (in.pressed(.space)) self.jumps += 1;
        if (in.released(.space)) self.landed += 1;
        if (in.pointerPressed(0)) self.clicks += 1;
        self.wheel += in.wheel().y;
    }
    pub fn draw(self: *Walker, _: *ui.Frame, _: Rect, alpha: f64) !void {
        self.alpha = alpha;
        self.draws += 1;
    }
};

const App = struct {
    walker: Walker = .{},
    loop: game.View = undefined,
    shown: bool = true,
    fn build(self: *App, v: *view.View) anyerror!void {
        try v.column(.{});
        _ = try v.button("Menu", .{});
        if (self.shown) try self.loop.build(v, .{ .grow = 1, .name = "Game" });
        try v.end();
    }
};

fn setUp(app: *App) void {
    app.loop = game.View.init(game.Game.bind(&app.walker));
}

test "steps are fixed whatever the frame rate, and catch up a quarter second at most" {
    var storage: Storage = .{};
    var app: App = .{};
    setUp(&app);
    var h = Harness.init(&app, App.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try testing.expectEqual(@as(usize, 0), app.walker.updates);
    // Frames of 120 Hz run a step every other frame.
    for (0..4) |_| try h.advance(step / 2);
    try testing.expectEqual(@as(usize, 2), app.walker.updates);
    try testing.expect(app.walker.alpha < 1);
    // A second away runs a quarter second's steps.
    try h.advance(std.time.ns_per_s);
    try testing.expectEqual(@as(usize, 2 + 15), app.walker.updates);
    // The view asks for the next frame.
    try testing.expect(h.deadline() != null);
    try testing.expect(app.walker.draws > 0);
}

test "the view takes focus as it appears, steps with the keys, and lets go without focus" {
    var storage: Storage = .{};
    var app: App = .{};
    setUp(&app);
    var h = Harness.init(&app, App.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    try testing.expectEqual(view.Kind.embed, h.focused().?.kind);

    // Keys by position: the key in D's place is held for two steps.
    try testing.expect(try h.key(.{ .key = .unknown, .physical = .d }));
    try h.advance(step);
    try h.advance(step);
    try testing.expectEqual(@as(f32, 4), app.walker.x);
    try testing.expect(app.walker.focused);
    try testing.expect(try h.keyUp(.{ .key = .unknown, .physical = .d }));
    try h.advance(step);
    try testing.expectEqual(@as(f32, 4), app.walker.x);

    // Pressed and released between two steps still counts once each.
    _ = try h.key(.{ .key = .space });
    _ = try h.key(.{ .key = .space, .repeat = true });
    _ = try h.keyUp(.{ .key = .space });
    try h.advance(step);
    try testing.expectEqual(@as(usize, 1), app.walker.jumps);
    try testing.expectEqual(@as(usize, 1), app.walker.landed);

    // Shortcuts go to the menus.
    try testing.expect(!try h.key(.{ .key = .q, .modifiers = .{ .control = true } }));

    // The window loses the keyboard: held keys are let go.
    _ = try h.key(.{ .key = .d });
    try h.advance(step);
    const x = app.walker.x;
    try h.windowFocus(false);
    try h.advance(step);
    try h.advance(step);
    try testing.expectEqual(x, app.walker.x);
    try testing.expect(!app.walker.focused);
}

test "pointer presses and the wheel reach the next step" {
    var storage: Storage = .{};
    var app: App = .{};
    setUp(&app);
    var h = Harness.init(&app, App.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    const leaf = try h.find(.{ .kind = .embed });
    const at = h.visible(leaf).?;
    try h.press(at.x + 10, at.y + 10, .{});
    try h.release(at.x + 10, at.y + 10);
    try h.wheel(at.x + 10, at.y + 10, .{ .x = 0, .y = 3 });
    try h.advance(step);
    try testing.expectEqual(@as(usize, 1), app.walker.clicks);
    try testing.expectEqual(@as(f32, 3), app.walker.wheel);
    try testing.expectEqual(@as(f32, 10), app.loop.in.pointer().x);
    try testing.expect(app.loop.in.pointer().over);
}

test "a game's own rate sets its steps" {
    const Slow = struct {
        pub const rate: u32 = 30;
        updates: usize = 0,
        pub fn update(self: *@This(), _: *const game.Input) void {
            self.updates += 1;
        }
        pub fn draw(_: *@This(), _: *ui.Frame, _: Rect, _: f64) !void {}
    };
    var slow: Slow = .{};
    var loop = game.View.init(game.Game.bind(&slow));
    _ = loop.advance(0);
    const alpha = loop.advance(std.time.ns_per_s / 20);
    try testing.expectEqual(@as(usize, 1), slow.updates);
    try testing.expectApproxEqAbs(@as(f64, 0.5), alpha, 1e-6);
    // Painting twice at one time runs no step twice.
    _ = loop.advance(std.time.ns_per_s / 20);
    try testing.expectEqual(@as(usize, 1), slow.updates);
}

test "integer fit letterboxes at whole multiples on whole pixels" {
    const fit = game.integerFit(1, 480, 270, .{ .x = 0, .y = 0, .width = 1000, .height = 600 });
    try testing.expectEqual(@as(u32, 2), fit.factor);
    try testing.expectEqual(Rect{ .x = 20, .y = 30, .width = 960, .height = 540 }, fit.destination);
    // At a scale of 1.5, three screen pixels per canvas pixel fit 1000 DIP.
    const scaled = game.integerFit(1.5, 480, 270, .{ .x = 0, .y = 0, .width = 1000, .height = 600 });
    try testing.expectEqual(@as(u32, 3), scaled.factor);
    try testing.expectEqual(@as(f32, 960), scaled.destination.width);
    // Too small still shows one pixel each.
    try testing.expectEqual(@as(u32, 1), game.integerFit(1, 480, 270, .{ .x = 0, .y = 0, .width = 100, .height = 100 }).factor);
    try testing.expectEqual(@as(u32, 0), game.integerFit(1, 0, 270, .{ .x = 0, .y = 0, .width = 100, .height = 100 }).factor);
}

test "the camera maps the world to the view and back" {
    const bounds: Rect = .{ .x = 100, .y = 50, .width = 200, .height = 100 };
    const cam: game.Camera = .{ .x = 10, .y = 20, .zoom = 2 };
    const t = try cam.transform(bounds);
    const center = try t.mapPoint(.{ .x = 10, .y = 20 });
    try testing.expectEqual(@as(f64, 200), center.x);
    try testing.expectEqual(@as(f64, 100), center.y);
    const world = cam.toWorld(bounds, 0, 0);
    try testing.expectEqual(@as(f32, 10 - 50), world.x);
    try testing.expectEqual(@as(f32, 20 - 25), world.y);
    const seen = cam.visible(bounds);
    try testing.expectEqual(Rect{ .x = -40, .y = -5, .width = 100, .height = 50 }, seen);

    // Turned a quarter, the view's right edge looks down the world.
    const turned: game.Camera = .{ .rotation = 90 };
    const right = turned.toWorld(bounds, bounds.width, bounds.height / 2);
    try testing.expectApproxEqAbs(@as(f32, 0), right.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), right.y, 1e-4);
    const back = try (try turned.transform(bounds)).mapPoint(.{ .x = right.x, .y = right.y });
    try testing.expectApproxEqAbs(@as(f64, bounds.x + bounds.width), back.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f64, bounds.y + bounds.height / 2), back.y, 1e-3);
    const box = turned.visible(bounds);
    try testing.expectApproxEqAbs(@as(f32, 100), box.width, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 200), box.height, 1e-3);
}

test "an unturned lens snaps to whole screen pixels and culls" {
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var frame: ui.Frame = .{ .context = &context, .size = .{ .width = 400, .height = 300, .scale = 2 } };
    const cam: game.Camera = .{ .x = 10.3, .y = 0, .zoom = 3 };
    const lens = cam.lens(&frame, .{ .x = 0, .y = 0, .width = 200, .height = 100 });
    const tile = lens.map(.{ .x = 16, .y = 0, .width = 16, .height = 16 });
    // 100 - 30.9 = 69.1 snaps to 69 at a scale of 2: tile edges on pixels.
    try testing.expectEqual(@as(f32, 69 + 48), tile.x);
    try testing.expectEqual(@as(f32, 48), tile.width);
    try testing.expect(lens.shows(.{ .x = 0, .y = 0, .width = 1, .height = 1 }));
    try testing.expect(!lens.shows(.{ .x = 500, .y = 0, .width = 16, .height = 16 }));
}
