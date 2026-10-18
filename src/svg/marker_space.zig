const std = @import("std");
const v = @import("ziggurat_vector");

// The two exact conformal forms are closed under the existing matrix builder's
// rotation/uniform-scale/reflection products. No tolerance admits shear.
pub fn pose(host: v.Transform, point: v.Point, angle: f64, width: f64, reference: v.Point) !v.Transform {
    inline for (std.meta.fields(v.Transform)) |field| if (!std.math.isFinite(@field(host, field.name))) return error.InvalidTransform;
    const direct = host.xx == host.yy and host.xy == -host.yx;
    const reflected = host.xx == -host.yy and host.xy == host.yx;
    if (!direct and !reflected) return error.UnsupportedMarkerStrokeSpace;
    const largest = @max(@abs(host.xx), @abs(host.yx));
    if (largest == 0) return error.UnsupportedMarkerStrokeSpace;
    // Normalize in two steps: neither host length nor its reciprocal needs to
    // be representable. Tiny positive scales do not create a huge w/s value.
    const a = host.xx / largest;
    const b = host.yx / largest;
    const length = std.math.hypot(a, b);
    const unit: v.Transform = .{
        .xx = a / length,
        .yx = b / length,
        .xy = (host.xy / largest) / length,
        .yy = (host.yy / largest) / length,
    };
    const cosine = @cos(angle);
    const sine = @sin(angle);
    const at = host.apply(point);
    const result = (v.Transform{ .x0 = -reference.x, .y0 = -reference.y })
        .then(.{ .xx = width, .yy = width })
        .then(.{ .xx = cosine, .yx = sine, .xy = -sine, .yy = cosine })
        .then(unit)
        .then(.{ .x0 = at.x, .y0 = at.y });
    inline for (std.meta.fields(v.Transform)) |field| if (!std.math.isFinite(@field(result, field.name))) return error.InvalidTransform;
    return result;
}
