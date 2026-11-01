//! Window chrome on AppKit: a frameless window keeps a hidden title bar,
//! transparent frames keep their alpha, materials and Liquid Glass sit
//! behind the content cut to the window's corners, presses in the hidden
//! title bar reach the content, and drag regions move the window.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
extern fn zlm_resource_count() u32;
extern fn zlm_test_paint(*anyopaque) void;
extern fn zlm_test_material(*anyopaque, *c_int, *f64) c_int;
extern fn zlm_test_container_radius(*anyopaque) f64;
extern fn zlm_test_window_opaque(*anyopaque) c_int;
extern fn zlm_test_buttons_hidden(*anyopaque) c_int;
extern fn zlm_test_titled(*anyopaque) c_int;
extern fn zlm_test_press(*anyopaque, f64, f64, c_int) void;
extern fn zlm_test_drag_begin(*anyopaque, f64, f64) void;
extern fn zlm_test_drag_start(*anyopaque) c_int;
extern fn zlmw_test_drag_phase() c_int;
extern fn zlmw_test_drag_to(f64, f64) void;
extern fn zlmw_test_drag_press(*f64, *f64) void;
extern fn zlc_test_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_layer_transparent(*anyopaque) c_int;

const Probe = struct {
    window: z.Window = undefined,
    content: ui.Context = undefined,
    downs: usize = 0,
    last_down: z.Point = .{ .x = 0, .y = 0 },
    transparent_frames: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (self.window.showsVibrancy()) self.transparent_frames += 1;
        // Only a square: the rest of a transparent frame stays clear.
        frame.rect(.{ .x = 10, .y = 40, .width = 20, .height = 20 }, 0xc0392b);
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (event) {
            .pointer_down => |value| {
                self.downs += 1;
                self.last_down = value.position;
                return true;
            },
            else => return false,
        }
    }
    /// The left half of the top 30 DIP is the caption; the rest is content.
    fn hit(_: *anyopaque, _: z.Window, point: z.Point) z.WindowHit {
        return if (point.y < 30 and point.x < 150) .caption else .client;
    }
    fn native(self: *Probe) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const app = try z.App.init(gpa.allocator());
    var probe: Probe = .{};
    probe.window = try app.createWindow(.{ .title = "chrome", .width = 300, .height = 200, .decoration = .borderless, .transparent = true, .vibrancy = .glass_clear, .corner_radius = 16, .hit_test = .{ .context = &probe, .query = Probe.hit } });
    probe.content = ui.Context.init(&probe, Probe.draw, Probe.action);
    probe.content.on_input = Probe.input;
    try probe.content.attach(probe.window);
    const native = probe.native();

    // Frameless: titled under the content, the title bar and its buttons
    // hidden; transparent and rounded: a clear window.
    try std.testing.expect(zlm_test_titled(native) != 0);
    try std.testing.expect(zlm_test_buttons_hidden(native) != 0);
    try std.testing.expect(zlm_test_window_opaque(native) == 0);
    try std.testing.expectEqual(@as(f64, 16), zlm_test_container_radius(native));
    const caps = try probe.window.capabilities();
    try std.testing.expect(caps.transparent and caps.vibrancy);
    try std.testing.expect(probe.window.showsVibrancy());

    // The clear glass, or the HUD material before macOS 26, cut to the corners.
    var style: c_int = 0;
    var radius: f64 = 0;
    const kind = zlm_test_material(native, &style, &radius);
    const glass = kind == 1;
    if (glass) try std.testing.expectEqual(@as(c_int, 1), style) else {
        try std.testing.expectEqual(@as(c_int, 0), kind);
        try std.testing.expectEqual(@as(c_int, 13), style);
    }
    try std.testing.expectEqual(@as(f64, 16), radius);
    try probe.window.setActiveAppearance(true);

    // Frames keep their alpha: only the square is drawn.
    zlm_test_paint(native);
    try std.testing.expect(probe.content.frames > 0 and probe.transparent_frames > 0);
    const surface = probe.content.renderer.native.?;
    try std.testing.expect(zlc_layer_transparent(surface) != 0);
    try std.testing.expectEqual(@as(u32, 0xc0392b), zlc_test_pixel(surface, 20, 50));
    try std.testing.expectEqual(@as(u32, 0), zlc_test_pixel(surface, 150, 120));

    // Another material keeps the corners; the regular glass comes back as
    // glass; no material leaves the frames transparent, as the window is.
    try probe.window.setVibrancy(.popover);
    try std.testing.expectEqual(@as(c_int, 0), zlm_test_material(native, &style, &radius));
    try std.testing.expectEqual(@as(c_int, 6), style);
    try std.testing.expectEqual(@as(f64, 16), radius);
    try probe.window.setVibrancy(.glass);
    try std.testing.expectEqual(@as(c_int, if (glass) 1 else 0), zlm_test_material(native, &style, &radius));
    try std.testing.expectEqual(@as(c_int, if (glass) 0 else 6), style);
    try probe.window.setVibrancy(.none);
    try std.testing.expectEqual(@as(c_int, -1), zlm_test_material(native, &style, &radius));
    try std.testing.expect(!probe.window.showsVibrancy());
    try std.testing.expect((try probe.window.capabilities()).transparent);

    probe.window.show();
    // A drag asked after the pointer moved since the press moves the window
    // here, keeping the pressed point under the pointer, and goes on with
    // the pointer's drags.
    const before = try probe.window.clientBounds();
    zlm_test_drag_begin(native, 60, 100);
    var px: f64 = 0;
    var py: f64 = 0;
    zlmw_test_drag_press(&px, &py);
    zlmw_test_drag_to(px + 6, py + 4);
    try std.testing.expectEqual(@as(c_int, 1), zlmw_test_drag_phase());
    try std.testing.expectEqual(@as(c_int, 1), zlm_test_drag_start(native));
    try std.testing.expectEqual(@as(c_int, 3), zlmw_test_drag_phase());
    var after = try probe.window.clientBounds();
    try std.testing.expectEqual(before.position.?.x + 6, after.position.?.x);
    try std.testing.expectEqual(before.position.?.y + 4, after.position.?.y);
    zlmw_test_drag_to(px + 16, py + 10);
    after = try probe.window.clientBounds();
    try std.testing.expectEqual(before.position.?.x + 16, after.position.?.x);
    try std.testing.expectEqual(before.position.?.y + 10, after.position.?.y);
    // A press asks once.
    try std.testing.expectEqual(@as(c_int, 2), zlm_test_drag_start(native));

    // A press in the hidden title bar, where the content is not a drag
    // region, reaches the content as AppKit delivers it.
    zlm_test_press(native, 220, 8, 1);
    try std.testing.expectEqual(@as(usize, 1), probe.downs);
    try std.testing.expectApproxEqAbs(@as(f32, 220), probe.last_down.x, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 8), probe.last_down.y, 1);
    // A press in a drag region is the window's, not the content's.
    zlm_test_press(native, 40, 8, 1);
    try std.testing.expectEqual(@as(usize, 1), probe.downs);

    // An opaque frameless window cut to its corners is made clear, its
    // frames opaque.
    var plain: Probe = .{};
    plain.window = try app.createWindow(.{ .title = "rounded", .width = 200, .height = 120, .decoration = .custom, .corner_radius = 12 });
    plain.content = ui.Context.init(&plain, Probe.draw, Probe.action);
    try plain.content.attach(plain.window);
    try std.testing.expect(zlm_test_window_opaque(plain.native()) == 0);
    try std.testing.expectEqual(@as(f64, 12), zlm_test_container_radius(plain.native()));
    try std.testing.expect(!(try plain.window.capabilities()).transparent);
    zlm_test_paint(plain.native());
    try std.testing.expectEqual(@as(u32, 0xffffff), zlc_test_pixel(plain.content.renderer.native.?, 150, 100));
    // A window with a title bar keeps it, and is not rounded.
    var framed: Probe = .{};
    framed.window = try app.createWindow(.{ .title = "framed", .width = 200, .height = 120, .corner_radius = 12 });
    try std.testing.expect(zlm_test_buttons_hidden(framed.native()) == 0);
    try std.testing.expect(zlm_test_window_opaque(framed.native()) != 0);
    try std.testing.expectError(error.InvalidGeometry, app.createWindow(.{ .corner_radius = -1 }));

    _ = try probe.window.destroy();
    _ = try plain.window.destroy();
    _ = try framed.window.destroy();
    try app.dispatch();
    app.deinit();
    try std.testing.expectEqual(@as(u32, 0), zlm_resource_count());
    std.debug.print("macOS chrome smoke passed ({s})\n", .{if (glass) "Liquid Glass" else "visual effect material"});
}
