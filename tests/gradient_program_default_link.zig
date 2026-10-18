const ui = @import("ziggurat_ui");
pub fn main() !void {
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{});
    defer renderer.deinit();
    if (try renderer.gradientInterpolationReady()) return error.UnexpectedDefaultProgram;
}
