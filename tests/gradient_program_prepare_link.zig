const ui = @import("ziggurat_ui");
pub fn main() !void {
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{});
    defer renderer.deinit();
    try renderer.prepareGradientInterpolation();
    defer renderer.releaseGradientInterpolation() catch unreachable;
    if (!(try renderer.gradientInterpolationReady())) return error.UnpreparedProgram;
}
