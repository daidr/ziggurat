//! A gallery of glass over colorful content: panes of each clarity, an
//! interactive glass button that lights as the pointer hovers it and grows
//! as it is pressed, a group of buttons on one pane of glass whose corners
//! merge while they are close (with a slider for how close), and, on macOS,
//! the window's own Liquid Glass with a tint. Reduce Transparency draws the
//! panes as opaque surfaces and higher contrast lights their rims.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");

const stops = [_]view.GradientStop{
    .{ .color = ui.Color.rgb(0xff5f6d), .at = 0 },
    .{ .color = ui.Color.rgb(0xffc371), .at = 0.35 },
    .{ .color = ui.Color.rgb(0x47cf73), .at = 0.65 },
    .{ .color = ui.Color.rgb(0x2f80ed), .at = 1 },
};
const tints = [_]?ui.Color{ null, .{ .r = 0x2f, .g = 0x80, .b = 0xed, .a = 90 }, .{ .r = 0xff, .g = 0x5f, .b = 0x6d, .a = 90 } };

const Gallery = struct {
    window: ?z.Window = null,
    button: view.GlassInteraction = .{},
    presses: usize = 0,
    /// How far apart the group's buttons stand, in DIP.
    spacing: f64 = 6,
    merge: bool = true,
    tint: usize = 0,

    fn build(self: *Gallery, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .gap = 18, .padding = view.Insets.all(24), .gradient = .{ .linear = .{ .angle = 120, .stops = &stops, .oklab = true } } });
        try v.text("Liquid glass", .{ .font = .{ .size = 22, .weight = .bold }, .color = 0xffffff });

        // Panes of each clarity over the same stripes.
        try v.row(.{ .gap = 12 });
        for ([_]f32{ 0, 0.5, 1 }, [_][]const u8{ "Frosted", "Clearer", "Clear" }) |clarity, label| {
            try v.column(.{ .width = 210, .height = 210, .radius = 24, .padding = view.Insets.all(14), .material = .{ .glass = .{ .clarity = clarity, .tint = tints[self.tint] } } });
            try v.text(label, .{ .font = .{ .weight = .semibold } });
            try v.textf("Clarity {d:.1}", .{clarity}, .{ .color = 0x3a3a3c });
            try v.end();
        }
        try v.end();

        // A glass button that lights on hover and grows while pressed.
        const area = try v.pointerArea(.{}, .{ .padding = .{ .top = 10, .bottom = 10, .left = 22, .right = 22 }, .radius = 20, .material = .{ .glass = try self.button.glass(v, .{ .tint = tints[self.tint] }) }, .name = "Interactive glass" });
        try v.textf("Pressed {d} times", .{self.presses}, .{ .font = .{ .weight = .semibold } });
        try v.end();
        try self.button.follow(v, area);
        if (area.clicked) self.presses += 1;

        // Buttons on one pane of glass, merging while they are close.
        try v.row(.{ .gap = @floatCast(self.spacing), .alignment = .center, .glass_group = .{ .radius = 20, .merge = if (self.merge) 24 else 0, .tint = tints[self.tint] } });
        for ([_][]const u8{ "Cut", "Copy", "Paste" }) |label| _ = try v.button(label, .{ .glass_pane = true, .padding = .{ .top = 8, .bottom = 8, .left = 18, .right = 18 }, .background = 0, .border_width = 0 });
        try v.end();
        try v.row(.{ .gap = 12, .alignment = .center, .self_align = .stretch });
        try v.textf("Apart {d:.0} DIP", .{self.spacing}, .{ .width = 110, .color = 0xffffff });
        _ = try v.slider(&self.spacing, .{ .minimum = 0, .maximum = 40, .step = 1 }, .{ .grow = 1, .name = "Spacing" });
        _ = try v.checkbox(&self.merge, "Merge", .{});
        try v.end();

        // The tint of the panes, and of the window's glass on macOS.
        try v.row(.{ .gap = 8 });
        for ([_][]const u8{ "No tint", "Blue tint", "Red tint" }, 0..) |label, i| {
            if (try v.button(label, .{ .enabled = self.tint != i })) {
                self.tint = i;
                if (self.window) |window| window.setVibrancyTint(if (tints[i]) |c| .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a } else null) catch {};
            }
        }
        try v.end();
        try v.end();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var gallery: Gallery = .{};
    var storage: view.Storage(256, 4096) = .{};
    var host = view.Host.init(&gallery, Gallery.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0) } });
    const app = try z.App.init(allocator);
    defer app.deinit();
    const library = try ui.effects.Library.create(allocator);
    defer library.destroy();
    const window = try app.createWindow(.{ .title = "Liquid glass", .width = 760, .height = 620, .vibrancy = if (@import("builtin").os.tag == .macos) .glass else .none });
    gallery.window = window;
    try host.attach(window);
    try host.prepareBackdropEffects(allocator, .{});
    try host.prepareShaderEffects(allocator, library, .{});
    window.show();
    try app.run();
}

fn harness(gallery: *Gallery, storage: anytype) view.Harness {
    return view.Harness.init(gallery, Gallery.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 760, .height = 620 }, .options = .{ .root = .{ .padding = view.Insets.all(0) } } });
}

test "the interactive glass counts its presses and the group's spacing follows the slider" {
    var gallery: Gallery = .{};
    var storage: view.Storage(256, 4096) = .{};
    var h = harness(&gallery, &storage);
    try h.render();
    const button = (try h.find(.{ .kind = .pointer_area })).bounds;
    try h.press(button.x + 4, button.y + 4, .{});
    try h.release(button.x + 4, button.y + 4);
    try std.testing.expectEqual(@as(usize, 1), gallery.presses);
    try h.render();
    _ = try h.find(.{ .text = "Pressed 1 times" });
    _ = try h.find(.{ .text = "Copy" });
    try h.click(.{ .text = "Blue tint" });
    try std.testing.expectEqual(@as(usize, 1), gallery.tint);
    try h.click(.{ .text = "Merge" });
    try std.testing.expect(!gallery.merge);
}
