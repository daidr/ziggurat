//! Opacities and masked clips drawn by Direct3D 11 (WARP) and by the
//! software planes (GDI): each drawing inside fades or shows through the
//! mask by itself, so two overlapping fills at half opacity show through
//! each other, unlike one layer faded at its end, and both renderers give
//! the same pixels.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const drawing = ui.drawing;
const resources = ui.gpu_resources;

const side = 64;

fn channel(pixel: u32, shift: u5) i32 {
    return @intCast((pixel >> shift) & 255);
}
fn near(what: []const u8, want: [3]i32, pixel: u32) !void {
    const got = [3]i32{ channel(pixel, 16), channel(pixel, 8), channel(pixel, 0) };
    for (want, got) |a, b| if (@abs(a - b) > 3) {
        std.debug.print("gpu masks smoke: {s}: expected rgb {any}, found {any} ({x})\n", .{ what, want, got, pixel });
        return error.PixelMismatch;
    };
}

/// White, then a red and a blue square overlapping at half opacity, then
/// a green square through a mask of half coverage.
fn scene(buffer: *ui.commands.Buffer, mask: drawing.CoverageView) !void {
    try buffer.fill(.{ .x = 0, .y = 0, .width = side, .height = side }, 0xffffff);
    try buffer.pushOpacity(128);
    try buffer.fill(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, 0xff0000);
    try buffer.fill(.{ .x = 16, .y = 16, .width = 32, .height = 32 }, 0x0000ff);
    try buffer.popClip();
    try buffer.pushMaskClip(.{ .x = 48, .y = 48, .width = 8, .height = 8 }, .{ .x = 48, .y = 48 }, mask);
    try buffer.fill(.{ .x = 40, .y = 40, .width = 24, .height = 24 }, 0x00ff00);
    try buffer.popClip();
}

fn check(name: []const u8, pixels: []const u32) !void {
    _ = name;
    // Red alone, at half.
    try near("red", .{ 255, 128, 128 }, pixels[8 * side + 8]);
    // Blue over red, each at half: they show through each other.
    try near("overlap", .{ 128, 64, 191 }, pixels[24 * side + 24]);
    // Blue alone, at half.
    try near("blue", .{ 128, 128, 255 }, pixels[40 * side + 40]);
    // Green through half the mask, and none of it outside the clip.
    try near("masked", .{ 128, 255, 128 }, pixels[52 * side + 52]);
    try near("outside the mask", .{ 255, 255, 255 }, pixels[44 * side + 60]);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const app = try z.App.init(allocator);
    defer app.deinit();
    const size: z.Size = .{ .width = side, .height = side, .scale = 1 };

    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    var coverage: [8 * 8]u8 = @splat(128);
    const mask: drawing.CoverageView = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &coverage, .width = 8, .height = 8, .stride = 8, .origin_x = 0, .origin_y = 0, .scale = 1 } };

    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try scene(&buffer, mask);

    // The software planes.
    {
        const surface = try ui.offscreen.Surface.create(app, allocator, .{ .size = size, .max_depth = 4 });
        defer surface.close() catch unreachable;
        const snapshot = try surface.render(&buffer);
        defer snapshot.close() catch unreachable;
        const view = try snapshot.view();
        const level = view.levels[0];
        var pixels: [side * side]u32 = undefined;
        for (0..side) |y| for (0..side) |x| {
            pixels[y * side + x] = std.mem.readInt(u32, level.pixels[y * level.stride + x * 4 ..][0..4], .little);
        };
        try check("software", &pixels);
    }
    // Direct3D 11 on WARP.
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .driver = .warp });
    defer domain.close() catch unreachable;
    const surface = try ui.gpu_offscreen.Surface.create(domain, allocator, .{ .size = size, .max_depth = 4 });
    defer surface.close() catch unreachable;
    try surface.uploadCoverage(mask);
    try surface.render(&buffer);
    var pixels: [side * side]u32 = undefined;
    try surface.readFrontForTest(&pixels);
    try check("Direct3D 11", &pixels);
    std.debug.print("gpu masks smoke: opacities and masked clips drew each drawing by itself on GDI and Direct3D 11\n", .{});
}
