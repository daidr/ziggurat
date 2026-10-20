const std = @import("std");
const shader = @import("root.zig");

fn build(source: []const u8) !*shader.Program {
    var diagnostic: shader.Diagnostic = .{};
    return shader.compile(std.testing.allocator, source, .{}, &diagnostic) catch |err| {
        std.debug.print("{d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message() });
        return err;
    };
}
fn expectDiagnostic(source: []const u8, line: u32, column: u32, needle: []const u8) !void {
    var diagnostic: shader.Diagnostic = .{};
    try std.testing.expectError(error.InvalidShader, shader.compile(std.testing.allocator, source, .{}, &diagnostic));
    std.testing.expect(diagnostic.line == line and diagnostic.column == column and std.mem.indexOf(u8, diagnostic.message(), needle) != null) catch |err| {
        std.debug.print("got {d}:{d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message() });
        return err;
    };
}
fn expectNear(expected: []const f32, actual: []const f32) !void {
    for (expected, actual) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-5);
}

test "a color program tints by a uniform" {
    const program = try build(
        \\uniform float amount;
        \\uniform vec4 tint;
        \\vec4 color(vec2 position, vec4 pixel) {
        \\    return mix(pixel, tint * pixel.a, amount);
        \\}
    );
    defer program.destroy();
    try std.testing.expectEqual(shader.Kind.color, program.kind);
    var values = shader.Values.init(program);
    try values.set(program.uniform("amount").?, @as(f32, 0.5));
    try values.set(program.uniform("tint").?, [4]f32{ 1, 0, 0, 1 });
    var machine: shader.Machine = .{};
    try machine.begin(program, &values, .{ 10, 10 }, 1);
    try expectNear(&.{ 0.25, 0, 0.25, 0.5 }, &try machine.color(.{ 1, 1 }, .{ 0, 0, 0.5, 0.5 }));
    try std.testing.expect(machine.steps <= program.max_steps);
}

test "distortion programs see their position, size and scale" {
    const program = try build(
        \\uniform float time;
        \\const float tau = 6.2831853;
        \\vec2 distort(vec2 position) {
        \\    float wave = sin(position.y / size.y * tau + time) * 2.0;
        \\    return position + vec2(wave, 0) * scale;
        \\}
    );
    defer program.destroy();
    var values = shader.Values.init(program);
    try values.set(program.uniform("time").?, @as(f32, std.math.pi / 2.0));
    var machine: shader.Machine = .{};
    try machine.begin(program, &values, .{ 40, 20 }, 2);
    try expectNear(&.{ 14, 0 }, &try machine.distort(.{ 10, 0 }));
}

test "layer programs read content through the sampler" {
    const program = try build(
        \\vec4 layer(vec2 position) {
        \\    vec4 sum = vec4(0.0);
        \\    for (int i = -2; i <= 2; i++) {
        \\        sum += sample(position + vec2(float(i), 0.0));
        \\    }
        \\    return sum / 5.0;
        \\}
    );
    defer program.destroy();
    const Content = struct {
        fn read(_: *const anyopaque, x: f32, _: f32) [4]f32 {
            return if (x >= 0) .{ 1, 1, 1, 1 } else .{ 0, 0, 0, 0 };
        }
    };
    var values = shader.Values.init(program);
    var machine: shader.Machine = .{};
    try machine.begin(program, &values, .{ 4, 4 }, 1);
    const dummy: u8 = 0;
    const result = try machine.layer(.{ 0, 0 }, .{ .context = &dummy, .function = Content.read });
    try expectNear(&.{ 0.6, 0.6, 0.6, 0.6 }, &result);
    try std.testing.expect(machine.steps <= program.max_steps);
}

test "helper functions, arrays, matrices and swizzle writes" {
    const program = try build(
        \\float weight(int i) {
        \\    float w[3];
        \\    w[0] = 0.25; w[1] = 0.5; w[2] = 0.25;
        \\    return w[i];
        \\}
        \\vec4 color(vec2 position, vec4 pixel) {
        \\    mat2 rotate = mat2(0.0, 1.0, -1.0, 0.0);
        \\    vec2 turned = rotate * position;
        \\    vec4 result = pixel;
        \\    result.xy = turned;
        \\    result.b = weight(0) + weight(1);
        \\    int count = 0;
        \\    for (int i = 0; i < 10; i++) {
        \\        if (i == 2) continue;
        \\        if (i >= 4) break;
        \\        count++;
        \\    }
        \\    result.a = float(count) + (position.x > 0.0 ? 0.5 : 0.0);
        \\    return result;
        \\}
    );
    defer program.destroy();
    var values = shader.Values.init(program);
    var machine: shader.Machine = .{};
    try machine.begin(program, &values, .{ 1, 1 }, 1);
    try expectNear(&.{ -2, 1, 0.75, 3.5 }, &try machine.color(.{ 1, 2 }, .{ 0, 0, 0, 0 }));
    try std.testing.expect(machine.steps <= program.max_steps);
}

test "worst-case steps are static and bounded" {
    const program = try build(
        \\vec2 distort(vec2 position) {
        \\    vec2 p = position;
        \\    for (int i = 0; i < 8; i++) { for (int j = 0; j < 8; j++) { p += vec2(0.001); } }
        \\    return p;
        \\}
    );
    defer program.destroy();
    var values = shader.Values.init(program);
    var machine: shader.Machine = .{};
    try machine.begin(program, &values, .{ 1, 1 }, 1);
    _ = try machine.distort(.{ 0, 0 });
    try std.testing.expect(machine.steps <= program.max_steps);
    try std.testing.expect(program.max_steps < 8 * 8 * 8);
    var diagnostic: shader.Diagnostic = .{};
    try std.testing.expectError(error.InvalidShader, shader.compile(std.testing.allocator,
        \\vec2 distort(vec2 position) {
        \\    vec2 p = position;
        \\    for (int i = 0; i < 1000; i++) { for (int j = 0; j < 1000; j++) { p += vec2(1.0); } }
        \\    return p;
        \\}
    , .{}, &diagnostic));
    try std.testing.expectEqual(@as(u32, 3), diagnostic.line);
}

test "compile errors name the exact position" {
    try expectDiagnostic("vec4 color(vec2 p, vec4 c) {\n  return c +;\n}", 2, 13, "expected an expression");
    try expectDiagnostic("vec4 color(vec2 p, vec4 c) {\n  return p;\n}", 2, 10, "expected vec4, got vec2");
    try expectDiagnostic("vec4 color(vec2 p, vec4 c) {\n  float x = 1.0;\n}", 3, 1, "can end without returning");
    try expectDiagnostic("vec2 distort(vec2 p) {\n  for (int i = 0; i < 4; i--) {}\n  return p;\n}", 2, 26, "never ends");
    try expectDiagnostic("vec2 distort(vec2 p) {\n  for (int i = 0; i < 4; i++) { i = 2; }\n  return p;\n}", 2, 33, "cannot assign");
    try expectDiagnostic("float f(float x) { return f(x); }\nvec2 distort(vec2 p) { return p; }", 1, 27, "cannot call itself");
    try expectDiagnostic("vec2 distort(vec2 p) { return sample(p).xy; }", 1, 31, "only available in a layer");
    try expectDiagnostic("uniform float t;\nvec2 distort(vec2 p) { t = 1.0; return p; }", 2, 24, "cannot assign");
    try expectDiagnostic("vec2 distort(vec2 p) { float a[2]; return p + a[2]; }", 1, 48, "out of range");
    try expectDiagnostic("vec4 colour(vec2 p, vec4 c) { return c; }", 1, 42, "none of color");
    try expectDiagnostic("vec4 color(vec2 p) { return vec4(p, 0.0, 1.0); }", 1, 6, "vec4 color(vec2 position, vec4 pixel)");
    try expectDiagnostic("vec2 distort(vec2 p) { return p @ 2; }", 1, 33, "unexpected character");
    try expectDiagnostic("vec2 distort(vec2 p) {\n  /* open", 2, 3, "unterminated comment");
    try expectDiagnostic("vec2 distort(vec2 p) { return p.xz; }", 1, 33, "invalid swizzle");
    try expectDiagnostic("vec2 distort(vec2 p) { p.xx = vec2(1.0); return p; }", 1, 24, "repeats a component");
}

test "runtime faults stop a run instead of wrapping or reading out of bounds" {
    const program = try build(
        \\uniform int index;
        \\uniform int big;
        \\vec4 color(vec2 position, vec4 pixel) {
        \\    float values[2];
        \\    int product = big * 2;
        \\    return vec4(values[index]) + float(product) * 0.0;
        \\}
    );
    defer program.destroy();
    var values = shader.Values.init(program);
    try values.set(program.uniform("index").?, @as(i32, 1));
    try values.set(program.uniform("big").?, @as(i32, 4));
    var machine: shader.Machine = .{};
    try machine.begin(program, &values, .{ 1, 1 }, 1);
    _ = try machine.color(.{ 0, 0 }, .{ 0, 0, 0, 0 });
    try values.set(program.uniform("index").?, @as(i32, 2));
    try machine.begin(program, &values, .{ 1, 1 }, 1);
    try std.testing.expectError(error.ShaderFault, machine.color(.{ 0, 0 }, .{ 0, 0, 0, 0 }));
    try values.set(program.uniform("index").?, @as(i32, 0));
    try values.set(program.uniform("big").?, @as(i32, std.math.maxInt(i32)));
    try machine.begin(program, &values, .{ 1, 1 }, 1);
    try std.testing.expectError(error.ShaderFault, machine.color(.{ 0, 0 }, .{ 0, 0, 0, 0 }));
}

test "uniform handles and values are typed and owned by one program" {
    const first = try build("uniform vec2 offset;\nuniform float k[3];\nvec2 distort(vec2 p) { return p + offset * k[1]; }");
    defer first.destroy();
    const second = try build("uniform vec2 offset;\nvec2 distort(vec2 p) { return p + offset; }");
    defer second.destroy();
    var values = shader.Values.init(first);
    try std.testing.expectError(error.UniformMismatch, values.set(second.uniform("offset").?, [2]f32{ 1, 1 }));
    try std.testing.expectError(error.UniformMismatch, values.set(first.uniform("offset").?, @as(f32, 1)));
    try std.testing.expectError(error.InvalidValue, values.set(first.uniform("offset").?, [2]f32{ std.math.nan(f32), 0 }));
    try values.set(first.uniform("offset").?, [2]f32{ 2, 4 });
    try values.set(first.uniform("k").?, &[3]f32{ 0, 0.5, 0 });
    try std.testing.expectError(error.UniformMismatch, values.setElement(first.uniform("k").?, 3, @as(f32, 1)));
    try std.testing.expect(first.uniform("missing") == null);
    // A recorded copy keeps its values after the original changes.
    const recorded = values;
    try values.set(first.uniform("offset").?, [2]f32{ 0, 0 });
    var machine: shader.Machine = .{};
    try std.testing.expectError(error.UniformMismatch, machine.begin(second, &recorded, .{ 1, 1 }, 1));
    try machine.begin(first, &recorded, .{ 1, 1 }, 1);
    try expectNear(&.{ 2, 3 }, &try machine.distort(.{ 1, 1 }));
}

test "compilation releases everything on failure and allocation failure" {
    const source =
        \\uniform float a;
        \\const float b = 2.0;
        \\vec4 color(vec2 position, vec4 pixel) { return pixel * a * b; }
    ;
    var diagnostic: shader.Diagnostic = .{};
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, text: []const u8, d: *shader.Diagnostic) !void {
            const program = try shader.compile(allocator, text, .{}, d);
            program.destroy();
        }
    }.run, .{ source, &diagnostic });
}
