pub const Document = @import("document.zig").Document;
pub const Limits = @import("document.zig").Limits;
pub const Node = @import("document.zig").Node;
pub const Stats = @import("document.zig").Stats;
pub const Color = @import("paint.zig").Color;
pub const PrepareOptions = @import("prepare.zig").Options;
pub const PrepareLimits = @import("prepare.zig").Limits;
pub const Prepared = @import("prepare.zig").Prepared;
pub const text = @import("text.zig");
pub const image = struct {
    pub const Provider = @import("image.zig").Provider;
    pub const Limits = @import("image.zig").Limits;
};

test {
    _ = @import("tests.zig");
    _ = @import("compiled_test.zig");
    _ = @import("scene_test.zig");
    _ = @import("sample_color_test.zig");
    _ = @import("budget_test.zig");
    _ = @import("own_mask_test.zig");
    _ = @import("radial_math_test.zig");
    _ = @import("radial_test.zig");
    _ = @import("text_test.zig");
    _ = @import("text_position_test.zig");
    _ = @import("paint_order_test.zig");
    _ = @import("text_length_test.zig");
    _ = @import("text_adjust_test.zig");
    _ = @import("text_cancel_test.zig");
    _ = @import("vector_effect_test.zig");
    _ = @import("text_paint_test.zig");
    _ = @import("text_path_test.zig");
    _ = @import("image_test.zig");
    _ = @import("pattern_test.zig");
    _ = @import("marker_test.zig");
}
