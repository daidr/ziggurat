//! Built-in programs on the shading language: a pose (2D and perspective
//! 3D transform of an element) and a refracting glass material for
//! backdrops. They are ordinary programs compiled once by `Library.create`.
const std = @import("std");
const zio = @import("ziggurat_io");
const shader = @import("ziggurat_shader");
const shader_effects = @import("shader_effects.zig");
const geometry = @import("geometry.zig");
pub const Effect = shader_effects.Effect;
pub const Color = geometry.Color;

pub const pose_source =
    \\uniform mat3 inverse;
    \\vec4 layer(vec2 position) {
    \\    vec3 q = inverse * vec3(position, 1.0);
    \\    if (q.z <= 0.0001) return vec4(0.0);
    \\    return sample(q.xy / q.z);
    \\}
;
/// Leaves content as it is; with an effect opacity it fades the content
/// as one isolated layer.
pub const passthrough_source =
    \\vec4 color(vec2 position, vec4 pixel) { return pixel; }
;
/// A Gaussian blur of the element's content by `sigma` DIP: 9 by 9 taps
/// over three deviations each way.
pub const blur_source =
    \\uniform float sigma;
    \\vec4 layer(vec2 position) {
    \\    vec4 sum = vec4(0.0);
    \\    float total = 0.0;
    \\    float spacing = sigma * 0.75;
    \\    for (int i = -4; i <= 4; i++) {
    \\        for (int j = -4; j <= 4; j++) {
    \\            vec2 k = vec2(float(i), float(j)) * 0.75;
    \\            float w = exp(-0.5 * dot(k, k));
    \\            sum += sample(position + vec2(float(i), float(j)) * spacing) * w;
    \\            total += w;
    \\        }
    \\    }
    \\    return sum / total;
    \\}
;
pub const glass_source =
    \\uniform float radius;
    \\uniform float bezel;
    \\uniform float refraction;
    \\uniform float highlight;
    \\uniform vec4 tint;
    \\float edge(vec2 p) {
    \\    vec2 half = size * 0.5;
    \\    vec2 q = abs(p - half) - (half - vec2(radius));
    \\    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    \\}
    \\vec4 layer(vec2 position) {
    \\    float depth = -edge(position);
    \\    vec2 normal = vec2(edge(position + vec2(0.5, 0.0)) - edge(position - vec2(0.5, 0.0)),
    \\                       edge(position + vec2(0.0, 0.5)) - edge(position - vec2(0.0, 0.5)));
    \\    float len = length(normal);
    \\    normal = len > 0.0 ? normal / len : vec2(0.0);
    \\    // A rounded bezel: the surface slopes most at the rim and is flat
    \\    // `bezel` DIP inside it; rays bend inward along the slope.
    \\    float u = clamp(1.0 - depth / bezel, 0.0, 1.0);
    \\    float slope = u / sqrt(max(1.0 - u * u, 0.04));
    \\    vec4 content = sample(position - normal * slope * refraction * bezel * 0.5);
    \\    content = vec4(mix(content.rgb, tint.rgb * content.a, tint.a), content.a);
    \\    // A rim of light on the top and bottom edges.
    \\    float rim = exp(-depth * depth / 2.0) * abs(normal.y) * highlight;
    \\    return vec4(mix(content.rgb, vec3(content.a), rim), content.a);
    \\}
;

/// Where and how an element sits relative to its laid-out box. Angles are
/// in degrees; rotations apply about `origin` (fractions of the box) in the
/// order scale, Z, X, Y, then translation. `perspective` is the viewer's
/// distance in DIP for X and Y rotations and `z`; zero is orthographic.
/// `x_percent` and `y_percent` move it further by percents of the box's own
/// width and height, as CSS's `translate(-50%, -50%)`, following its size.
pub const Pose = struct {
    x: f32 = 0,
    y: f32 = 0,
    x_percent: f32 = 0,
    y_percent: f32 = 0,
    z: f32 = 0,
    /// Moves the content `depth` DIP toward the viewer before it turns, as
    /// CSS's `translateZ()` written before `rotateY()`: it pushes the
    /// content out from the axis it turns about, as the items of a
    /// carousel on a ring, where `z` lifts the turned content toward the
    /// viewer. Seen in `perspective`, nearer looks larger and farther
    /// smaller; content as far as the viewer or past it shows nothing.
    depth: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,
    rotate: f32 = 0,
    rotate_x: f32 = 0,
    rotate_y: f32 = 0,
    perspective: f32 = 800,
    origin: [2]f32 = .{ 0.5, 0.5 },

    pub fn isIdentity(self: Pose) bool {
        return self.x == 0 and self.y == 0 and self.x_percent == 0 and self.y_percent == 0 and self.z == 0 and self.depth == 0 and self.scale_x == 1 and self.scale_y == 1 and self.rotate == 0 and self.rotate_x == 0 and self.rotate_y == 0;
    }
    pub fn valid(self: Pose) bool {
        inline for (zio.fields(Pose)) |field| {
            if (field.type == f32 and !std.math.isFinite(@field(self, field.name))) return false;
        }
        return std.math.isFinite(self.origin[0]) and std.math.isFinite(self.origin[1]) and self.perspective >= 0;
    }
    /// Linear interpolation between two poses, for transitions.
    pub fn mix(a: Pose, b: Pose, t: f32) Pose {
        var result = a;
        inline for (zio.fields(Pose)) |field| {
            if (field.type == f32) @field(result, field.name) = @field(a, field.name) + (@field(b, field.name) - @field(a, field.name)) * t;
        }
        result.origin = .{ a.origin[0] + (b.origin[0] - a.origin[0]) * t, a.origin[1] + (b.origin[1] - a.origin[1]) * t };
        return result;
    }
    /// The move along x of a box `width` wide: `x` and `x_percent` of it.
    pub fn offsetX(self: Pose, width: f32) f32 {
        return self.x + self.x_percent / 100 * width;
    }
    /// The move along y of a box `height` tall.
    pub fn offsetY(self: Pose, height: f32) f32 {
        return self.y + self.y_percent / 100 * height;
    }
    /// The pose with its percents resolved into `x` and `y` for a box of
    /// `size`.
    pub fn resolved(self: Pose, size: [2]f32) Pose {
        var result = self;
        result.x = self.offsetX(size[0]);
        result.y = self.offsetY(size[1]);
        result.x_percent = 0;
        result.y_percent = 0;
        return result;
    }
    /// Whether the pose turns the front of the content, which faces the
    /// viewer, away: whether its normal, by the inverse transpose of the
    /// pose's 4×4 map, perspective included, points away, as Chromium's
    /// `IsBackFaceVisible` has it, so that content pushed off its axis by
    /// `depth` faces where the viewer sees it from, as the items at the
    /// sides of a carousel turn their backs as they pass the viewer's line.
    /// See `view.Style.backface_hidden`.
    pub fn facesAway(self: Pose) bool {
        if (self.rotate_x == 0 and self.rotate_y == 0) return false;
        const radians = std.math.pi / 180.0;
        const cz = @cos(@as(f64, self.rotate) * radians);
        const sz = @sin(@as(f64, self.rotate) * radians);
        const cx = @cos(@as(f64, self.rotate_x) * radians);
        const sx = @sin(@as(f64, self.rotate_x) * radians);
        const cy = @cos(@as(f64, self.rotate_y) * radians);
        const sy = @sin(@as(f64, self.rotate_y) * radians);
        // The columns of R = Ry * Rx * Rz times the scales: x, y and z.
        var axes: [3][3]f64 = undefined;
        for (0..3) |i| {
            const v0 = [3]f64{ if (i == 0) self.scale_x else 0, if (i == 1) self.scale_y else 0, if (i == 2) 1 else 0 };
            const v1 = [3]f64{ v0[0] * cz - v0[1] * sz, v0[0] * sz + v0[1] * cz, v0[2] };
            const v2 = [3]f64{ v1[0], v1[1] * cx - v1[2] * sx, v1[1] * sx + v1[2] * cx };
            axes[i] = .{ v2[0] * cy + v2[2] * sy, v2[1], -v2[0] * sy + v2[2] * cy };
        }
        const d: f64 = self.depth;
        const moved = [3]f64{ self.x + d * cx * sy, self.y - d * sx, self.z + d * cx * cy };
        const k: f64 = if (self.perspective > 0) 1 / @as(f64, self.perspective) else 0;
        // Rows of the 4×4 map about the origin: the turn and the move, then
        // the perspective's w = 1 - z / distance.
        const m = [4][4]f64{
            .{ axes[0][0], axes[1][0], axes[2][0], moved[0] },
            .{ axes[0][1], axes[1][1], axes[2][1], moved[1] },
            .{ axes[0][2], axes[1][2], axes[2][2], moved[2] },
            .{ -k * axes[0][2], -k * axes[1][2], -k * axes[2][2], 1 - k * moved[2] },
        };
        const det3 = struct {
            fn of(a: [4][4]f64, r: [3]usize, c: [3]usize) f64 {
                return a[r[0]][c[0]] * (a[r[1]][c[1]] * a[r[2]][c[2]] - a[r[1]][c[2]] * a[r[2]][c[1]]) -
                    a[r[0]][c[1]] * (a[r[1]][c[0]] * a[r[2]][c[2]] - a[r[1]][c[2]] * a[r[2]][c[0]]) +
                    a[r[0]][c[2]] * (a[r[1]][c[0]] * a[r[2]][c[1]] - a[r[1]][c[1]] * a[r[2]][c[0]]);
            }
        }.of;
        // The determinant along the last column; the inverse's entry at row
        // and column 2 is the cofactor there over it.
        const det = -m[0][3] * det3(m, .{ 1, 2, 3 }, .{ 0, 1, 2 }) + m[1][3] * det3(m, .{ 0, 2, 3 }, .{ 0, 1, 2 }) - m[2][3] * det3(m, .{ 0, 1, 3 }, .{ 0, 1, 2 }) + m[3][3] * det3(m, .{ 0, 1, 2 }, .{ 0, 1, 2 });
        if (det == 0 or !std.math.isFinite(det)) return false;
        return det3(m, .{ 0, 1, 3 }, .{ 0, 1, 3 }) * det < 0;
    }
    /// Column-major homography from box-relative content DIP to box-relative
    /// screen DIP, for a box of `size`.
    pub fn homography(self: Pose, size: [2]f32) [9]f64 {
        const ox = @as(f64, self.origin[0]) * size[0];
        const oy = @as(f64, self.origin[1]) * size[1];
        const radians = std.math.pi / 180.0;
        const cz = @cos(@as(f64, self.rotate) * radians);
        const sz = @sin(@as(f64, self.rotate) * radians);
        const cx = @cos(@as(f64, self.rotate_x) * radians);
        const sx = @sin(@as(f64, self.rotate_x) * radians);
        const cy = @cos(@as(f64, self.rotate_y) * radians);
        const sy = @sin(@as(f64, self.rotate_y) * radians);
        // Columns of R = Ry * Rx * Rz, applied to scaled unit axes.
        var axes: [2][3]f64 = undefined;
        for (0..2) |i| {
            // Each step reads the vector before it: an array literal
            // assigned to the array it reads would alias it.
            const v0 = [3]f64{ if (i == 0) self.scale_x else 0, if (i == 1) self.scale_y else 0, 0 };
            const v1 = [3]f64{ v0[0] * cz - v0[1] * sz, v0[0] * sz + v0[1] * cz, v0[2] };
            const v2 = [3]f64{ v1[0], v1[1] * cx - v1[2] * sx, v1[1] * sx + v1[2] * cx };
            axes[i] = .{ v2[0] * cy + v2[2] * sy, v2[1], -v2[0] * sy + v2[2] * cy };
        }
        // v(x, y) = a1 x + a2 y + a0, relative to the origin.
        const tx = self.offsetX(size[0]);
        const ty = self.offsetY(size[1]);
        // The depth moves along the content's own Z, turned with it.
        const d: f64 = self.depth;
        const pushed = [3]f64{ d * cx * sy, -d * sx, d * cx * cy };
        const a0 = [3]f64{ tx + pushed[0] - axes[0][0] * ox - axes[1][0] * oy, ty + pushed[1] - axes[0][1] * ox - axes[1][1] * oy, self.z + pushed[2] - axes[0][2] * ox - axes[1][2] * oy };
        const k: f64 = if (self.perspective > 0) 1 / @as(f64, self.perspective) else 0;
        // Screen = origin + v.xy / w with w = 1 - v.z / perspective.
        return .{
            axes[0][0] - ox * axes[0][2] * k, axes[0][1] - oy * axes[0][2] * k, -axes[0][2] * k,
            axes[1][0] - ox * axes[1][2] * k, axes[1][1] - oy * axes[1][2] * k, -axes[1][2] * k,
            a0[0] + ox * (1 - a0[2] * k),     a0[1] + oy * (1 - a0[2] * k),     1 - a0[2] * k,
        };
    }
};

/// Inverse of a column-major 3x3 matrix, or null when it is singular.
pub fn inverse3(m: [9]f64) ?[9]f64 {
    const a = m[0];
    const b = m[3];
    const c = m[6];
    const d = m[1];
    const e = m[4];
    const f = m[7];
    const g = m[2];
    const h = m[5];
    const i = m[8];
    const A = e * i - f * h;
    const B = -(d * i - f * g);
    const C = d * h - e * g;
    const det = a * A + b * B + c * C;
    if (!(@abs(det) > 1e-12) or !std.math.isFinite(det)) return null;
    const inv = 1 / det;
    // Row-major adjugate, transposed into column-major storage.
    const rows = [9]f64{
        A, -(b * i - c * h), b * f - c * e,
        B, a * i - c * g,    -(a * f - c * d),
        C, -(a * h - b * g), a * e - b * d,
    };
    return .{ rows[0] * inv, rows[3] * inv, rows[6] * inv, rows[1] * inv, rows[4] * inv, rows[7] * inv, rows[2] * inv, rows[5] * inv, rows[8] * inv };
}
fn apply(m: [9]f64, x: f64, y: f64) ?[2]f64 {
    const w = m[2] * x + m[5] * y + m[8];
    if (!(w > 1e-4)) return null;
    return .{ (m[0] * x + m[3] * y + m[6]) / w, (m[1] * x + m[4] * y + m[7]) / w };
}

/// Glass that bends what lies beneath a rounded rectangle at its bezel and
/// lights its top and bottom rims. Draw it with `Frame.backdropShader`.
pub const Glass = struct {
    /// Width of the curved rim in DIP.
    bezel: f32 = 16,
    /// How far rays bend: 0 is flat, 1 bends up to half a bezel.
    refraction: f32 = 0.6,
    /// Rim light from 0 to 1.
    highlight: f32 = 0.35,
    /// Straight-alpha tint mixed in by its alpha.
    tint: ?Color = null,
};

/// The built-in programs, compiled once. Keep the Library alive while any
/// frame records one of its effects.
pub const Library = struct {
    allocator: std.mem.Allocator,
    pose_program: *shader.Program,
    glass_program: *shader.Program,
    passthrough_program: *shader.Program,
    passthrough_values: shader.Values,
    blur_program: *shader.Program,
    /// Largest margin a pose may claim around its box, in DIP; content
    /// moved farther is clipped.
    max_pose_margin: f32 = 128,

    pub fn create(allocator: std.mem.Allocator) !*Library {
        var diagnostic: shader.Diagnostic = .{};
        const pose_program = shader.compile(allocator, pose_source, .{}, &diagnostic) catch |err| return builtinFailure(err);
        errdefer pose_program.destroy();
        const glass_program = shader.compile(allocator, glass_source, .{}, &diagnostic) catch |err| return builtinFailure(err);
        errdefer glass_program.destroy();
        const passthrough_program = shader.compile(allocator, passthrough_source, .{}, &diagnostic) catch |err| return builtinFailure(err);
        errdefer passthrough_program.destroy();
        const blur_program = shader.compile(allocator, blur_source, .{}, &diagnostic) catch |err| return builtinFailure(err);
        errdefer blur_program.destroy();
        const self = try allocator.create(Library);
        self.* = .{ .allocator = allocator, .pose_program = pose_program, .glass_program = glass_program, .passthrough_program = passthrough_program, .passthrough_values = shader.Values.init(passthrough_program), .blur_program = blur_program };
        return self;
    }
    fn builtinFailure(err: error{ InvalidShader, OutOfMemory }) error{OutOfMemory} {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // The built-in sources are tested; they always compile.
            error.InvalidShader => unreachable,
        };
    }
    pub fn destroy(self: *Library) void {
        self.pose_program.destroy();
        self.glass_program.destroy();
        self.passthrough_program.destroy();
        self.blur_program.destroy();
        self.allocator.destroy(self);
    }
    /// The built-in programs and how they draw, for
    /// `Context.prepareGpuShaders`.
    pub fn gpuShaders(self: *const Library) [4]shader_effects.GpuShader {
        return .{
            .{ .program = self.passthrough_program, .target = .element },
            .{ .program = self.pose_program, .target = .element },
            .{ .program = self.glass_program, .target = .backdrop },
            .{ .program = self.blur_program, .target = .element },
        };
    }
    /// Largest blur `blur` draws, in DIP; more blurs as much.
    pub const max_blur: f32 = 64;
    /// An element effect that blurs a box's content by `sigma` DIP, as a
    /// Gaussian of that deviation, spreading it as far as three times that
    /// past the box; null for no blur. `values` receives the uniforms and
    /// must outlive the recording call.
    pub fn blur(self: *const Library, values: *shader.Values, sigma: f32) !?Effect {
        if (!std.math.isFinite(sigma) or sigma < 0) return error.InvalidBlur;
        if (sigma < 0.05) return null;
        const amount = @min(sigma, max_blur);
        values.* = shader.Values.init(self.blur_program);
        try values.set(self.blur_program.uniform("sigma").?, amount);
        return .{ .program = self.blur_program, .values = values, .margin = @ceil(amount * 3) };
    }
    /// An element effect that changes nothing, for fading content as one
    /// layer through `EffectOptions.opacity`.
    pub fn passthrough(self: *const Library) Effect {
        return .{ .program = self.passthrough_program, .values = &self.passthrough_values, .margin = 0 };
    }
    /// An element effect that draws a box of `size` DIP at `pose`, or null
    /// when the pose is the identity or degenerate (nothing would show).
    /// `values` receives the uniforms and must outlive the recording call.
    pub fn pose(self: *const Library, values: *shader.Values, value: Pose, size: [2]f32) !?Effect {
        if (!value.valid()) return error.InvalidPose;
        if (value.isIdentity()) return null;
        const forward = value.homography(size);
        // The origin at or behind the viewer, as a move along Z as far as
        // the perspective's distance puts it: nothing shows, as in CSS.
        const ox = @as(f64, value.origin[0]) * size[0];
        const oy = @as(f64, value.origin[1]) * size[1];
        if (!(forward[2] * ox + forward[5] * oy + forward[8] > 1e-4)) return null;
        const back = inverse3(forward) orelse return null;
        // Claim the margin the moved corners need.
        var margin: f32 = 0;
        for ([_][2]f64{ .{ 0, 0 }, .{ size[0], 0 }, .{ 0, size[1] }, .{ size[0], size[1] } }) |corner| {
            const point = apply(forward, corner[0], corner[1]) orelse {
                margin = self.max_pose_margin;
                break;
            };
            const outside = @max(@max(-point[0], point[0] - size[0]), @max(-point[1], point[1] - size[1]));
            margin = @max(margin, @as(f32, @floatCast(@min(outside, self.max_pose_margin))));
        }
        values.* = shader.Values.init(self.pose_program);
        var columns: [9]f32 = undefined;
        for (back, 0..) |entry, i| columns[i] = @floatCast(entry);
        values.set(self.pose_program.uniform("inverse").?, columns) catch return null;
        return .{ .program = self.pose_program, .values = values, .margin = @ceil(margin) };
    }
    /// A backdrop shader for a rounded rectangle with corner `radius`.
    pub fn glass(self: *const Library, values: *shader.Values, value: Glass, radius: f32) !Effect {
        values.* = shader.Values.init(self.glass_program);
        const program = self.glass_program;
        try values.set(program.uniform("radius").?, @as(f32, @max(radius, 0)));
        try values.set(program.uniform("bezel").?, @as(f32, @max(value.bezel, 0.5)));
        try values.set(program.uniform("refraction").?, std.math.clamp(value.refraction, 0, 4));
        try values.set(program.uniform("highlight").?, std.math.clamp(value.highlight, 0, 1));
        const tint = value.tint orelse Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        try values.set(program.uniform("tint").?, [4]f32{ @as(f32, @floatFromInt(tint.r)) / 255, @as(f32, @floatFromInt(tint.g)) / 255, @as(f32, @floatFromInt(tint.b)) / 255, @as(f32, @floatFromInt(tint.a)) / 255 });
        return .{ .program = program, .values = values, .margin = value.bezel * @max(value.refraction, 0) * 2 + 1 };
    }
};

test "a blur spreads its content three deviations past its box" {
    const library = try Library.create(std.testing.allocator);
    defer library.destroy();
    var values: shader.Values = undefined;
    try std.testing.expect(try library.blur(&values, 0) == null);
    try std.testing.expectError(error.InvalidBlur, library.blur(&values, -1));
    const effect = (try library.blur(&values, 4)).?;
    try std.testing.expectEqual(@as(f32, 12), effect.margin);
    try std.testing.expectEqual(library.blur_program, effect.program);
    // Larger blurs blur as much as the largest.
    try std.testing.expectEqual(Library.max_blur * 3, (try library.blur(&values, 1000)).?.margin);
    try std.testing.expectEqual(@as(usize, 4), library.gpuShaders().len);
}

test "percents of a pose move by the box's own size" {
    const pose: Pose = .{ .x = 4, .x_percent = -50, .y_percent = 100 };
    try std.testing.expect(!pose.isIdentity());
    try std.testing.expect(!(Pose{ .y_percent = 1 }).isIdentity());
    const h = pose.homography(.{ 40, 20 });
    // The top left corner moves by 4 - 20 along x and by the height along y.
    try std.testing.expectApproxEqAbs(@as(f64, -16), h[6] / h[8], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 20), h[7] / h[8], 1e-9);
    const flat = pose.resolved(.{ 40, 20 });
    try std.testing.expectEqual(@as(f32, -16), flat.x);
    try std.testing.expectEqual(@as(f32, 20), flat.y);
    try std.testing.expectEqual(@as(f32, 0), flat.x_percent);
    const halfway = Pose.mix(.{}, .{ .y_percent = 100 }, 0.5);
    try std.testing.expectEqual(@as(f32, 50), halfway.y_percent);
}

test "identity and translated poses map content corners" {
    const library = try Library.create(std.testing.allocator);
    defer library.destroy();
    var values: shader.Values = undefined;
    try std.testing.expect(try library.pose(&values, .{}, .{ 40, 20 }) == null);
    const moved = (try library.pose(&values, .{ .x = 10, .y = -4 }, .{ 40, 20 })).?;
    try std.testing.expectEqual(@as(f32, 10), moved.margin);
    var machine: shader.Machine = .{};
    try machine.begin(moved.program, moved.values, .{ 40, 20 }, 1);
    const Read = struct {
        fn position(_: *const anyopaque, x: f32, y: f32) [4]f32 {
            return .{ x, y, 0, 1 };
        }
    };
    const dummy: u8 = 0;
    const result = try machine.layer(.{ 15, 6 }, .{ .context = &dummy, .function = Read.position });
    try std.testing.expectApproxEqAbs(@as(f32, 5), result[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10), result[1], 1e-4);
}

test "a pose faces away past a quarter turn, and a carousel's side items as they pass" {
    try std.testing.expect(!(Pose{ .rotate_y = 80 }).facesAway());
    try std.testing.expect((Pose{ .rotate_y = 100 }).facesAway());
    try std.testing.expect((Pose{ .rotate_x = 180 }).facesAway());
    try std.testing.expect(!(Pose{ .rotate_y = 360 }).facesAway());
    // A flip shows the back face of the other side: the two faces of a card.
    try std.testing.expect(!(Pose{ .rotate_y = 30 + 180 + 180 }).facesAway());
    try std.testing.expect((Pose{ .rotate_y = 30 + 180 }).facesAway());
    // Mirrored in 2D, it still faces the viewer.
    try std.testing.expect(!(Pose{ .scale_x = -1 }).facesAway());
    // Pushed out from its axis on a ring and turned 80 degrees, its plane
    // passes the viewer's line before a quarter turn, in perspective.
    try std.testing.expect((Pose{ .depth = 300, .rotate_y = 80, .perspective = 600 }).facesAway());
    try std.testing.expect(!(Pose{ .depth = 300, .rotate_y = 80, .perspective = 0 }).facesAway());
}

test "a half turn about the centre and a perspective tilt" {
    const turn = (Pose{ .rotate = 180 }).homography(.{ 40, 20 });
    const corner = apply(turn, 0, 0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 40), corner[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 20), corner[1], 1e-9);
    const back = inverse3(turn).?;
    const round_trip = apply(back, corner[0], corner[1]).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), round_trip[0], 1e-9);
    // A quarter turn clockwise: the top left corner goes to the top right
    // of the turned box, about the middle.
    const quarter = (Pose{ .rotate = 90 }).homography(.{ 40, 20 });
    const top_left_turned = apply(quarter, 0, 0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 30), top_left_turned[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -10), top_left_turned[1], 1e-9);
    const right_turned = apply(quarter, 40, 0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 30), right_turned[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 30), right_turned[1], 1e-9);
    // Turning about Y moves the right edge away: it projects shorter.
    const tilt = (Pose{ .rotate_y = 30, .perspective = 200 }).homography(.{ 100, 100 });
    const top_right = apply(tilt, 100, 0).?;
    const bottom_right = apply(tilt, 100, 100).?;
    const top_left = apply(tilt, 0, 0).?;
    const bottom_left = apply(tilt, 0, 100).?;
    try std.testing.expect(bottom_right[1] - top_right[1] < bottom_left[1] - top_left[1]);
    try std.testing.expect(top_right[0] < 100);
    // A flat Y turn of 90 degrees is edge-on: nothing to draw.
    const library = try Library.create(std.testing.allocator);
    defer library.destroy();
    var values: shader.Values = undefined;
    try std.testing.expect(try library.pose(&values, .{ .rotate_y = 90, .perspective = 0 }, .{ 10, 10 }) == null);
    try std.testing.expectError(error.InvalidPose, library.pose(&values, .{ .x = std.math.inf(f32) }, .{ 10, 10 }));
}

test "a move along Z scales about the origin in perspective, before or after a turn" {
    // 120 DIP back seen from 800: 800/920 its size about the middle.
    const back = (Pose{ .z = -120, .perspective = 800 }).homography(.{ 100, 100 });
    const corner = apply(back, 0, 0).?;
    try std.testing.expectApproxEqAbs(50 - 50 * 800.0 / 920.0, corner[0], 1e-9);
    // Unturned, depth moves the same way as z.
    const pushed = (Pose{ .depth = -120, .perspective = 800 }).homography(.{ 100, 100 });
    try std.testing.expectApproxEqAbs(corner[0], apply(pushed, 0, 0).?[0], 1e-9);
    // Pushed out 100 then turned a quarter about Y, the middle goes to the
    // side: depth turns with the content, z does not.
    const ring = (Pose{ .depth = 100, .rotate_y = 90, .perspective = 0 }).homography(.{ 100, 100 });
    try std.testing.expectApproxEqAbs(@as(f64, 150), apply(ring, 50, 50).?[0], 1e-9);
    const lifted = (Pose{ .z = 100, .rotate_y = 90, .perspective = 0 }).homography(.{ 100, 100 });
    try std.testing.expectApproxEqAbs(@as(f64, 50), apply(lifted, 50, 50).?[0], 1e-9);
    // As far as the viewer or past it, nothing shows.
    const library = try Library.create(std.testing.allocator);
    defer library.destroy();
    var values: shader.Values = undefined;
    try std.testing.expect(try library.pose(&values, .{ .z = 800, .perspective = 800 }, .{ 10, 10 }) == null);
    try std.testing.expect(try library.pose(&values, .{ .z = 900, .perspective = 800 }, .{ 10, 10 }) == null);
    try std.testing.expect(try library.pose(&values, .{ .z = 100, .perspective = 800 }, .{ 10, 10 }) != null);
}

test "glass bends the backdrop near its rim and leaves the middle" {
    const library = try Library.create(std.testing.allocator);
    defer library.destroy();
    var values: shader.Values = undefined;
    const effect = try library.glass(&values, .{ .bezel = 8, .refraction = 1, .highlight = 0 }, 4);
    var machine: shader.Machine = .{};
    try machine.begin(effect.program, effect.values, .{ 40, 40 }, 1);
    const Read = struct {
        fn position(_: *const anyopaque, x: f32, y: f32) [4]f32 {
            return .{ x / 100, y / 100, 0, 1 };
        }
    };
    const dummy: u8 = 0;
    const middle = try machine.layer(.{ 20, 20 }, .{ .context = &dummy, .function = Read.position });
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), middle[0], 1e-4);
    // Near the left rim the read moves inward (to larger x).
    const rim = try machine.layer(.{ 1, 20 }, .{ .context = &dummy, .function = Read.position });
    try std.testing.expect(rim[0] > 0.01 + 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), rim[1], 1e-4);
}
