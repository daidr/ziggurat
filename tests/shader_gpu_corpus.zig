//! Programs, uniforms and per-pixel inputs shared by the GPU/CPU parity
//! checks of translated shaders.
const std = @import("std");
const shader = @import("ziggurat_shader");

pub const width = 32;
pub const height = 16;

pub const Case = struct {
    name: []const u8,
    source: []const u8,
    /// Sets uniforms on freshly initialized values.
    setup: ?*const fn (program: *const shader.Program, values: *shader.Values) anyerror!void = null,
};

fn setTime(program: *const shader.Program, values: *shader.Values) anyerror!void {
    try values.set(program.uniform("time").?, @as(f32, 1.25));
}
fn setTint(program: *const shader.Program, values: *shader.Values) anyerror!void {
    try values.set(program.uniform("amount").?, @as(f32, 0.4));
    try values.set(program.uniform("tint").?, [4]f32{ 0.9, 0.2, 0.1, 1 });
    try values.set(program.uniform("weights").?, &[3]f32{ 0.25, 0.5, 0.25 });
}
fn setInts(program: *const shader.Program, values: *shader.Values) anyerror!void {
    try values.set(program.uniform("divisor").?, @as(i32, 7));
    try values.set(program.uniform("big").?, @as(i32, std.math.maxInt(i32) - 20));
}

pub const cases = [_]Case{
    .{ .name = "tint", .setup = setTint, .source = 
    \\uniform float amount;
    \\uniform vec4 tint;
    \\uniform float weights[3];
    \\const float boost = amount * 2.0;
    \\vec4 color(vec2 position, vec4 pixel) {
    \\    vec4 mixed = mix(pixel, tint * pixel.a, boost);
    \\    return mixed * (weights[0] + weights[1] + weights[2]) + vec4(step(0.0, position.x) * 0.1);
    \\}
    },
    .{ .name = "wave", .setup = setTime, .source = 
    \\uniform float time;
    \\const float tau = 6.2831853;
    \\vec2 distort(vec2 position) {
    \\    float wave = sin(position.y / size.y * tau + time) * 2.0;
    \\    return position + vec2(wave, cos(position.x * 0.3)) * scale;
    \\}
    },
    .{ .name = "blur", .source = 
    \\vec4 layer(vec2 position) {
    \\    vec4 sum = vec4(0.0);
    \\    for (int i = -2; i <= 2; i++) {
    \\        for (int j = -1; j <= 1; j++) {
    \\            if (j == 0 && i == 1) continue;
    \\            sum += sample(position + vec2(float(i), float(j)));
    \\        }
    \\    }
    \\    return sum / 14.0;
    \\}
    },
    .{ .name = "functions", .source = 
    \\float weight(int i) {
    \\    float w[3];
    \\    w[0] = 0.25; w[1] = 0.5; w[2] = 0.25;
    \\    return w[i];
    \\}
    \\vec2 turn(vec2 p, float angle) {
    \\    mat2 rotate = mat2(cos(angle), sin(angle), -sin(angle), cos(angle));
    \\    return rotate * p;
    \\}
    \\vec4 color(vec2 position, vec4 pixel) {
    \\    vec4 result = pixel;
    \\    result.xy = turn(position, 0.7) * 0.1;
    \\    result.b = weight(int(mod(floor(position.x), 3.0))) + weight(1);
    \\    int count = 0;
    \\    for (int i = 0; i < 10; i++) {
    \\        if (i == 2) continue;
    \\        if (float(i) >= position.y) break;
    \\        count++;
    \\    }
    \\    result.a = float(count) + (position.x > 0.0 ? 0.5 : 0.0);
    \\    return result;
    \\}
    },
    .{ .name = "math", .source = 
    \\vec4 color(vec2 position, vec4 pixel) {
    \\    float a = pow(position.x, 2.0) + pow(-2.0, 3.0) + atan(position.y, position.x);
    \\    float b = round(position.x * 0.5) + sign(position.y) + fract(position.x) + mod(position.x, 2.5);
    \\    vec3 n = normalize(vec3(position, 1.0));
    \\    vec3 c = cross(n, vec3(0.0, 0.0, 1.0));
    \\    float d = distance(position, vec2(1.0, 2.0)) + length(c) + dot(n, n);
    \\    float e = smoothstep(-2.0, 2.0, position.x) + clamp(position.y, -1.0, 1.0) + abs(position.x) + exp(-abs(position.y)) + log(1.0 + abs(position.x));
    \\    mat3 m = mat3(1.0, 2.0, 3.0, 0.0, 1.0, 4.0, 5.0, 6.0, 0.0);
    \\    vec3 f = (m * m) * n + n * m;
    \\    return vec4(a * 0.1, b, d + e, f.x + f.y * 0.5 + f.z * 0.25 + sqrt(abs(position.x)) + inversesqrt(1.0 + abs(position.y)) + floor(position.y) + ceil(position.x) + exp2(position.x * 0.1) + log2(2.0 + position.y) + tan(position.x * 0.1) + asin(0.3) + acos(0.4) + atan(position.y));
    \\}
    },
    .{ .name = "ints", .setup = setInts, .source = 
    \\uniform int divisor;
    \\uniform int big;
    \\vec4 color(vec2 position, vec4 pixel) {
    \\    int x = int(position.x * 4.0);
    \\    int y = int(position.y);
    \\    int q = x / divisor + x % divisor + y * 3 - min(x, y) + max(x, -y);
    \\    int r = y != 0 ? 100 / y : 0;
    \\    int s = 10 / (x - 4);
    \\    int t = big + x;
    \\    bool flag = x > 2 && !(y == 1) || x == -5;
    \\    return vec4(float(q), float(r), float(s + t - big), flag ? 1.0 : 0.0);
    \\}
    },
    .{ .name = "arrays", .source = 
    \\vec2 distort(vec2 position) {
    \\    vec2 points[4];
    \\    points[0] = vec2(1.0, 0.0); points[1] = vec2(0.0, 1.0); points[2] = vec2(-1.0, 0.0); points[3] = vec2(0.0, -1.0);
    \\    int i = int(floor(position.x)) + 3;
    \\    vec2 p = points[i];
    \\    points[int(position.y) + 2] = p * 2.0;
    \\    return position + p + points[1];
    \\}
    },
};

/// The position and pixel color each pixel (x, y) runs with.
pub fn position(x: usize, y: usize) [2]f32 {
    return .{ @as(f32, @floatFromInt(x)) * 0.37 - 3.0, @as(f32, @floatFromInt(y)) * 0.53 - 2.0 };
}
pub fn pixel(x: usize, y: usize) [4]f32 {
    return .{ @as(f32, @floatFromInt(x)) / width, @as(f32, @floatFromInt(y)) / height, 0.25, 0.75 };
}
/// The content layer programs sample.
pub fn content(_: *const anyopaque, x: f32, y: f32) [4]f32 {
    const a = x * 0.13;
    const b = y * 0.07;
    return .{ a - @floor(a), b - @floor(b), 0.5, 1 };
}
pub const size = [2]f32{ 40, 20 };
pub const scale: f32 = 1.5;

/// The CPU's result for pixel (x, y), or null for a fault.
pub fn expected(machine: *shader.Machine, program: *const shader.Program, x: usize, y: usize) ?[4]f32 {
    const dummy: u8 = 0;
    return switch (program.kind) {
        .color => machine.color(position(x, y), pixel(x, y)) catch null,
        .distortion => if (machine.distort(position(x, y))) |p| .{ p[0], p[1], 0, 0 } else |_| null,
        .layer => machine.layer(position(x, y), .{ .context = &dummy, .function = content }) catch null,
    };
}

/// Whether a GPU value matches the CPU's closely enough: transcendental
/// functions differ in their last bits between implementations.
pub fn near(expected_value: f32, actual: f32) bool {
    if (std.math.isNan(expected_value)) return std.math.isNan(actual);
    if (std.math.isInf(expected_value)) return expected_value == actual;
    return @abs(expected_value - actual) <= 2e-3 + @abs(expected_value) * 1e-4;
}

/// Compare a GPU's results and statuses (1 where the run finished) with
/// the CPU machine's for every pixel. Returns how many pixels fault.
pub fn compare(name: []const u8, machine: *shader.Machine, program: *const shader.Program, result: []const f32, status: []const f32) !usize {
    var faults: usize = 0;
    for (0..height) |y| for (0..width) |x| {
        const at = (y * width + x) * 4;
        const ok = status[at] == 1;
        const want = expected(machine, program, x, y);
        if (want == null) faults += 1;
        if ((want != null) != ok) {
            std.debug.print("{s} ({d}, {d}): CPU {s}, GPU {s}\n", .{ name, x, y, if (want == null) "faults" else "runs", if (ok) "runs" else "faults" });
            return error.FaultMismatch;
        }
        const value = want orelse continue;
        const components: usize = if (program.kind == .distortion) 2 else 4;
        for (0..components) |k| if (!near(value[k], result[at + k])) {
            std.debug.print("{s} ({d}, {d})[{d}]: CPU {d}, GPU {d}\n", .{ name, x, y, k, value[k], result[at + k] });
            return error.ValueMismatch;
        };
    };
    return faults;
}

/// Compile a case and run its prologue on `machine`.
pub fn prepare(allocator: std.mem.Allocator, case: Case, machine: *shader.Machine) !*shader.Program {
    var diagnostic: shader.Diagnostic = .{};
    const program = shader.compile(allocator, case.source, .{}, &diagnostic) catch |err| {
        std.debug.print("{s}: {d}:{d}: {s}\n", .{ case.name, diagnostic.line, diagnostic.column, diagnostic.message() });
        return err;
    };
    errdefer program.destroy();
    var values = shader.Values.init(program);
    if (case.setup) |setup| try setup(program, &values);
    try machine.begin(program, &values, size, scale);
    return program;
}
