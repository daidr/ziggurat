//! What games need beyond what applications do, opt-in and out of the core
//! view layer: a loop that advances a game's world in fixed steps with the
//! player's input and draws it every frame (`View`), a camera that looks at
//! a 2D world (`Camera`), pixel-perfect scaling of a logical canvas
//! (`integerFit`), and game controllers (`gamepad`).
//!
//!     const Farm = struct {
//!         x: f32 = 0,
//!         pub fn update(self: *Farm, in: *const game.Input) void {
//!             if (in.down(.d)) self.x += 2;
//!         }
//!         pub fn draw(self: *Farm, frame: *ui.Frame, bounds: view.Rect, alpha: f64) !void { ... }
//!     };
//!     var loop = game.View.init(game.Game.bind(&farm));
//!     // in the build function:
//!     try loop.build(v, .{ .grow = 1, .name = "Farm" });
//!
//! Everything runs on the main thread. The loop allocates nothing; the
//! application keeps the `View` at a stable address while it is built.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");

pub const gamepad = @import("gamepad.zig");

const Rect = view.Rect;
const Point = view.Point;
const affine = ui.affine;
const KeyCode = z.KeyCode;
const KeySet = std.EnumSet(KeyCode);

/// Steps a second a View runs a game whose `rate` is 0.
pub const rate: u32 = 60;
/// The most time steps catch up on after a pause, such as a window out of
/// sight, in nanoseconds.
pub const max_catch_up: u64 = 250 * std.time.ns_per_ms;
/// How often a shown View asks for a frame, in nanoseconds.
pub const frame_interval: u64 = view.loading_frame_interval;
/// Pointer buttons Input follows: 0 is the primary.
pub const pointer_buttons = 3;

/// What the player did, as a step sees it: the keys and pointer buttons
/// held, and those pressed and released since the step before, even when
/// pressed and released between two steps. Keys are by position
/// (`z.KeyInput.physical`): `.w` is the key in W's place on any layout.
pub const Input = struct {
    held: KeySet = .initEmpty(),
    pressed_keys: KeySet = .initEmpty(),
    released_keys: KeySet = .initEmpty(),
    at: Point = .{},
    inside: bool = false,
    buttons: [pointer_buttons]bool = @splat(false),
    buttons_pressed: [pointer_buttons]bool = @splat(false),
    buttons_released: [pointer_buttons]bool = @splat(false),
    scrolled: Point = .{},
    width: f32 = 0,
    height: f32 = 0,
    has_focus: bool = false,

    /// `key` is held.
    pub fn down(self: *const Input, key: KeyCode) bool {
        return self.held.contains(key);
    }
    /// `key` was pressed since the step before.
    pub fn pressed(self: *const Input, key: KeyCode) bool {
        return self.pressed_keys.contains(key);
    }
    /// `key` was released since the step before.
    pub fn released(self: *const Input, key: KeyCode) bool {
        return self.released_keys.contains(key);
    }
    pub const Pointer = struct { x: f32, y: f32, over: bool };
    /// Where the pointer is, from the view's top-left corner, and whether
    /// it is over the view.
    pub fn pointer(self: *const Input) Pointer {
        return .{ .x = self.at.x, .y = self.at.y, .over = self.inside };
    }
    /// Pointer button `button` (0 the primary, 1 the secondary, 2 the
    /// middle) is held. Views receive the primary button only, so the
    /// others read released.
    pub fn pointerDown(self: *const Input, button: usize) bool {
        return button < pointer_buttons and self.buttons[button];
    }
    /// `button` was pressed since the step before.
    pub fn pointerPressed(self: *const Input, button: usize) bool {
        return button < pointer_buttons and self.buttons_pressed[button];
    }
    /// `button` was released since the step before.
    pub fn pointerReleased(self: *const Input, button: usize) bool {
        return button < pointer_buttons and self.buttons_released[button];
    }
    /// How far the wheel or touchpad scrolled since the step before, in
    /// DIP, down and right positive.
    pub fn wheel(self: *const Input) Point {
        return self.scrolled;
    }
    pub const Size = struct { width: f32, height: f32 };
    /// The view's size.
    pub fn size(self: *const Input) Size {
        return .{ .width = self.width, .height = self.height };
    }
    /// The view has the keyboard, which it loses with its window or to
    /// another control: a game pauses without it, as the player is
    /// elsewhere.
    pub fn focused(self: *const Input) bool {
        return self.has_focus;
    }

    /// Forget what happened before this step.
    fn step(self: *Input) void {
        self.pressed_keys = .initEmpty();
        self.released_keys = .initEmpty();
        self.buttons_pressed = @splat(false);
        self.buttons_released = @splat(false);
        self.scrolled = .{};
    }
    /// Let go of everything held, as when the window loses the keyboard,
    /// whose releases never come.
    fn releaseAll(self: *Input) void {
        self.released_keys.setUnion(self.held);
        self.held = .initEmpty();
        for (&self.buttons, &self.buttons_released) |*held, *released_button| {
            if (held.*) released_button.* = true;
            held.* = false;
        }
    }
    fn keyDown(self: *Input, input: z.KeyInput) void {
        const key = position(input);
        if (!input.repeat and !self.held.contains(key)) self.pressed_keys.insert(key);
        self.held.insert(key);
    }
    fn keyUp(self: *Input, input: z.KeyInput) void {
        const key = position(input);
        if (!self.held.contains(key)) return;
        self.released_keys.insert(key);
        self.held.remove(key);
    }
    fn setButton(self: *Input, index: usize, is_down: bool) void {
        if (is_down and !self.buttons[index]) self.buttons_pressed[index] = true;
        if (!is_down and self.buttons[index]) self.buttons_released[index] = true;
        self.buttons[index] = is_down;
    }
    fn move(self: *Input, point: Point) void {
        self.at = point;
        self.inside = point.x >= 0 and point.y >= 0 and point.x < self.width and point.y < self.height;
    }
    fn position(key: z.KeyInput) KeyCode {
        return if (key.physical != .unknown) key.physical else key.key;
    }
};

/// A game a View runs: `update` advances its world one step of 1/rate
/// seconds with the input since the step before, and `draw` draws it every
/// frame. `alpha`, from 0 to 1, is how far the frame's time is into the
/// next step: a game may draw what moves that far between its last two
/// places, for motion smoother than its steps.
pub const Game = struct {
    context: *anyopaque,
    update: *const fn (*anyopaque, *const Input) void,
    draw: *const fn (*anyopaque, *ui.Frame, Rect, f64) anyerror!void,
    /// Steps a second; 0 is `rate`.
    rate: u32 = 0,

    /// Bind a pointer to a struct with `update(self, *const Input) void` and
    /// `draw(self, *ui.Frame, Rect, f64) !void`, and optionally a
    /// `pub const rate: u32`.
    pub fn bind(state: anytype) Game {
        const T = @typeInfo(@TypeOf(state)).pointer.child;
        const Adapter = struct {
            fn update(ptr: *anyopaque, in: *const Input) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                self.update(in);
            }
            fn draw(ptr: *anyopaque, frame: *ui.Frame, bounds: Rect, alpha: f64) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.draw(frame, bounds, alpha);
            }
        };
        return .{
            .context = state,
            .update = Adapter.update,
            .draw = Adapter.draw,
            .rate = if (@hasDecl(T, "rate")) T.rate else 0,
        };
    }
    fn stepLength(self: Game) u64 {
        return std.time.ns_per_s / @as(u64, if (self.rate == 0) rate else self.rate);
    }
};

/// Runs a game in an embedded leaf: `update` in fixed steps of the game's
/// rate with the keys, pointer and wheel the leaf takes as Input, whatever
/// the display's rate, and `draw` every frame while it is built. The leaf
/// takes the keyboard focus as it first appears and when pressed, leaves
/// keys with Ctrl, Alt or Super to shortcuts and menus, and lets go of
/// what was held when it or its window loses the keyboard. Keep it at a
/// stable address while builds use it.
pub const View = struct {
    game: Game,
    in: Input = .{},
    /// The time of the last frame that ran steps.
    last: ?u64 = null,
    /// Time not yet stepped, in nanoseconds.
    lag: u64 = 0,
    /// The time of the latest pass.
    now: u64 = 0,
    /// The leaf's node id, learned when it is first painted.
    id: ?u64 = null,
    asked_focus: bool = false,
    /// Steps run so far.
    steps: u64 = 0,

    pub fn init(game: Game) View {
        return .{ .game = game };
    }

    /// Add the leaf to the build, sized by `style` like any node (for
    /// example `.grow = 1` to fill), and ask for the next frame.
    pub fn build(self: *View, v: *view.View, style: view.Style) view.Error!void {
        self.now = v.time();
        const has_keyboard = if (self.id) |id| v.hasKeyboard(id) else false;
        if (!has_keyboard) self.in.releaseAll();
        self.in.has_focus = has_keyboard;
        if (self.id) |id| if (!self.asked_focus) {
            self.asked_focus = true;
            v.focusLeaf(id);
        };
        try v.embed(.{
            .context = self,
            .measure = measure,
            .paint = paint,
            .focusable = true,
            .input = onInput,
        }, style);
        v.wakeAt(self.now + frame_interval);
    }

    /// Run the steps due at `now`, then return how far into the next step
    /// it is; `paint` does this with the pass's time.
    pub fn advance(self: *View, now: u64) f64 {
        const length = self.game.stepLength();
        // Painting twice at one time runs no step twice.
        if (self.last) |last| self.lag += @min(now -| last, max_catch_up);
        self.last = now;
        while (self.lag >= length) {
            self.game.update(self.game.context, &self.in);
            self.in.step();
            self.lag -= length;
            self.steps += 1;
        }
        return @as(f64, @floatFromInt(self.lag)) / @as(f64, @floatFromInt(length));
    }

    fn measure(_: *anyopaque, _: view.Theme) ui.layout.Measurement {
        return .{ .minimum = .{ .width = 0, .height = 0 }, .preferred = .{ .width = 320, .height = 240 } };
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *View = @ptrCast(@alignCast(ptr));
        self.id = id;
        self.in.width = bounds.width;
        self.in.height = bounds.height;
        const alpha = self.advance(self.now);
        try self.game.draw(self.game.context, frame, bounds, alpha);
    }
    fn onInput(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *View = @ptrCast(@alignCast(ptr));
        const in = &self.in;
        switch (event) {
            .key => |key| {
                // The menus' shortcuts.
                if (key.modifiers.control or key.modifiers.alt or key.modifiers.super) return false;
                in.keyDown(key);
            },
            .key_up => |key| in.keyUp(key),
            .pointer_down => |press| {
                in.move(press.position);
                in.setButton(0, true);
            },
            .pointer_drag => |drag| in.move(drag.position),
            .pointer_up => |at| {
                in.move(at);
                in.setButton(0, false);
            },
            .pointer_cancel => in.setButton(0, false),
            .pointer_move => |at| in.move(at),
            .pointer_leave => in.inside = false,
            .wheel => |scroll| {
                in.scrolled.x += scroll.delta.x;
                in.scrolled.y += scroll.delta.y;
            },
        }
        return true;
    }
};

pub const Fit = struct {
    /// Where the canvas shows, in DIP.
    destination: Rect,
    /// Screen pixels for each of the canvas's own, at least 1; 0 for an
    /// empty canvas.
    factor: u32,
};

/// Where a canvas of `width`×`height` pixels shows in `bounds` as large as
/// it can with a whole number of screen pixels for each of its own, at
/// least one, centered (letterboxed): pixel-perfect scaling for pixel art.
/// `scale` is the frame's (`frame.size.scale`). Draw the canvas there with
/// nearest sampling. The pointer at x, y of the view is at
/// ((x + bounds.x - dst.x) * width / dst.width, ...) of the canvas.
pub fn integerFit(scale: f32, width: u32, height: u32, bounds: Rect) Fit {
    if (width == 0 or height == 0) return .{ .destination = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .factor = 0 };
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const fitted = @floor(@min(bounds.width * scale / w, bounds.height * scale / h));
    const factor: u32 = if (fitted >= 1) @intFromFloat(fitted) else 1;
    const k: f32 = @floatFromInt(factor);
    const dw = w * k / scale;
    const dh = h * k / scale;
    // On whole pixels of the screen.
    const x = @floor((bounds.x + (bounds.width - dw) / 2) * scale + 0.5) / scale;
    const y = @floor((bounds.y + (bounds.height - dh) / 2) * scale + 0.5) / scale;
    return .{ .destination = .{ .x = x, .y = y, .width = dw, .height = dh }, .factor = factor };
}

/// A camera looking at a 2D world: the world's point x, y shows at the
/// middle of the view, `zoom` times as large (0 is 1), turned `rotation`
/// degrees. World units are DIP at a zoom of 1.
pub const Camera = struct {
    x: f32 = 0,
    y: f32 = 0,
    zoom: f32 = 0,
    rotation: f32 = 0,

    fn factor(self: Camera) f32 {
        return if (self.zoom == 0) 1 else self.zoom;
    }

    /// The transform from the world to the window for the view `bounds`.
    pub fn transform(self: Camera, bounds: Rect) affine.Error!affine.Affine {
        const k: f64 = self.factor();
        var t = try affine.Affine.translation(.{ .x = -self.x, .y = -self.y });
        if (self.rotation != 0) t = try t.then(try affine.Affine.rotation(-radians(self.rotation)));
        t = try t.then(try affine.Affine.scaling(.{ .x = k, .y = k }));
        return t.then(try affine.Affine.translation(.{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 }));
    }

    /// The world's point at x, y of the view `bounds`, from its top-left
    /// corner, as `Input.pointer` gives it.
    pub fn toWorld(self: Camera, bounds: Rect, x: f32, y: f32) Point {
        const k = self.factor();
        var dx = (x - bounds.width / 2) / k;
        var dy = (y - bounds.height / 2) / k;
        if (self.rotation != 0) {
            const a: f32 = @floatCast(radians(self.rotation));
            const s = @sin(a);
            const c = @cos(a);
            const turned_x = dx * c - dy * s;
            dy = dx * s + dy * c;
            dx = turned_x;
        }
        return .{ .x = self.x + dx, .y = self.y + dy };
    }

    /// The part of the world the camera shows in the view `bounds`: its
    /// bounds when turned. A game draws only the tiles in it.
    pub fn visible(self: Camera, bounds: Rect) Rect {
        const corners = [4]Point{
            self.toWorld(bounds, 0, 0),
            self.toWorld(bounds, bounds.width, 0),
            self.toWorld(bounds, 0, bounds.height),
            self.toWorld(bounds, bounds.width, bounds.height),
        };
        var low = corners[0];
        var high = corners[0];
        for (corners[1..]) |c| {
            low = .{ .x = @min(low.x, c.x), .y = @min(low.y, c.y) };
            high = .{ .x = @max(high.x, c.x), .y = @max(high.y, c.y) };
        }
        return .{ .x = low.x, .y = low.y, .width = high.x - low.x, .height = high.y - low.y };
    }

    /// Draw what `draw_world` draws in world coordinates through the camera
    /// into `bounds`, clipped to it. `draw_world(context, *Lens)` draws with
    /// the Lens, which maps world rectangles to the frame. Unturned, the
    /// world moves by whole screen pixels so that tiles drawn at whole world
    /// units keep their edges on them. A turned camera draws through a
    /// frame transform, which needs `ui.Context.prepareTransforms` with a
    /// source size that holds the visible world.
    pub fn draw(self: Camera, frame: *ui.Frame, bounds: Rect, context: anytype, comptime draw_world: fn (@TypeOf(context), *Lens) anyerror!void) anyerror!void {
        try frame.pushClip(bounds);
        defer frame.popClip() catch {};
        if (self.rotation == 0) {
            var flat = self.lens(frame, bounds);
            return draw_world(context, &flat);
        }
        const seen = self.visible(bounds);
        const to_parent = try (try affine.Affine.translation(.{ .x = seen.x, .y = seen.y })).then(try self.transform(bounds));
        try frame.beginTransform(.{ .width = seen.width, .height = seen.height }, to_parent);
        defer frame.endTransform() catch {};
        var turned: Lens = .{ .frame = frame, .scale = 1, .offset = .{ .x = -seen.x, .y = -seen.y }, .seen = seen };
        try draw_world(context, &turned);
    }

    /// The unturned mapping `draw` uses, for drawing without a clip.
    pub fn lens(self: Camera, frame: *ui.Frame, bounds: Rect) Lens {
        const k = self.factor();
        const s = frame.size.scale;
        const snap = struct {
            fn at(v: f32, pixels: f32) f32 {
                return @round(v * pixels) / pixels;
            }
        }.at;
        return .{
            .frame = frame,
            .scale = k,
            .offset = .{ .x = snap(bounds.x + bounds.width / 2 - self.x * k, s), .y = snap(bounds.y + bounds.height / 2 - self.y * k, s) },
            .seen = self.visible(bounds),
        };
    }
};

/// Draws in world coordinates through a camera: each rectangle is mapped
/// to the frame, then drawn with the frame's own call.
pub const Lens = struct {
    frame: *ui.Frame,
    scale: f32,
    offset: Point,
    /// The world the camera shows, for culling.
    seen: Rect,

    /// The frame rectangle of a world rectangle.
    pub fn map(self: *const Lens, world: Rect) Rect {
        return .{ .x = world.x * self.scale + self.offset.x, .y = world.y * self.scale + self.offset.y, .width = world.width * self.scale, .height = world.height * self.scale };
    }
    /// The world rectangle overlaps what the camera shows.
    pub fn shows(self: *const Lens, world: Rect) bool {
        return world.x < self.seen.x + self.seen.width and world.y < self.seen.y + self.seen.height and world.x + world.width > self.seen.x and world.y + world.height > self.seen.y;
    }
    pub fn rect(self: *const Lens, world: Rect, rgb: u32) void {
        if (self.shows(world)) self.frame.rect(self.map(world), rgb);
    }
    pub fn roundedRect(self: *const Lens, world: Rect, radius: f32, color: ui.Color) void {
        if (self.shows(world)) self.frame.roundedRect(self.map(world), radius * self.scale, color);
    }
    pub fn strokeRect(self: *const Lens, world: Rect, radius: f32, width: f32, color: ui.Color) void {
        if (self.shows(world)) self.frame.strokeRect(self.map(world), radius * self.scale, width * self.scale, color);
    }
    pub fn image(self: *const Lens, world: Rect, picture: ui.drawing.ImageView, options: ui.ImageOptions) !void {
        if (self.shows(world)) try self.frame.image(self.map(world), picture, options);
    }
    pub fn label(self: *const Lens, world: Rect, text: []const u8, rgb: u32) void {
        if (self.shows(world)) self.frame.label(self.map(world), text, rgb);
    }
};

fn radians(degrees: f32) f64 {
    return @as(f64, degrees) * std.math.pi / 180;
}

test {
    _ = gamepad;
    _ = @import("tests.zig");
}
