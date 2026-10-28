//! Translated shader programs draw on OpenGL what the CPU machine computes,
//! pixel for pixel, faults included.
const std = @import("std");
const shader = @import("ziggurat_shader");
const corpus = @import("shader_gpu_corpus.zig");

extern fn zsg_init(log: [*]u8, log_len: usize) c_int;
extern fn zsg_run(source: [*:0]const u8, words: [*]const u32, word_count: u32, width: u32, height: u32, result: [*]f32, status: [*]f32, log: [*]u8, log_len: usize) c_int;

fn host(allocator: std.mem.Allocator, translation: *const shader.gpu.Translation) ![:0]u8 {
    const vectors = @max((translation.inputs.len + 3) / 4, 1);
    return std.fmt.allocPrintSentinel(allocator,
        \\#version 330 core
        \\layout(std140) uniform ZsWords {{ uvec4 zs_words[{d}]; }};
        \\uint zs_input(uint i) {{ return zs_words[i >> 2u][i & 3u]; }}
        \\vec4 zs_sample(vec2 p) {{ float a = p.x * 0.13; float b = p.y * 0.07; return vec4(a - floor(a), b - floor(b), 0.5, 1.0); }}
        \\{s}
        \\out vec4 zs_result;
        \\out vec4 zs_status;
        \\void main() {{
        \\    float x = floor(gl_FragCoord.x);
        \\    float y = floor(gl_FragCoord.y);
        \\    vec2 position = vec2(x * 0.37 - 3.0, y * 0.53 - 2.0);
        \\    vec4 pixel = vec4(x / {d}.0, y / {d}.0, 0.25, 0.75);
        \\    vec4 result;
        \\    bool ok = zs_run(position, pixel, result);
        \\    zs_result = result;
        \\    zs_status = vec4(ok ? 1.0 : 0.0);
        \\}}
        \\
    , .{ vectors, translation.source, corpus.width, corpus.height }, 0);
}

test "translated programs match the CPU machine on OpenGL" {
    const allocator = std.testing.allocator;
    var log: [4096]u8 = @splat(0);
    if (zsg_init(&log, log.len) != 0) {
        std.debug.print("OpenGL unavailable: {s}\n", .{std.mem.sliceTo(&log, 0)});
        return error.SkipZigTest;
    }
    for (corpus.cases) |case| {
        var machine: shader.Machine = .{};
        const program = try corpus.prepare(allocator, case, &machine);
        defer program.destroy();
        var translation = try shader.gpu.translate(allocator, program, .glsl);
        defer translation.deinit();
        var words: [shader.gpu.max_input_words]u32 = undefined;
        translation.gather(&machine, &words);
        const source = try host(allocator, &translation);
        defer allocator.free(source);
        var result: [corpus.width * corpus.height * 4]f32 = undefined;
        var status: [corpus.width * corpus.height * 4]f32 = undefined;
        @memset(&log, 0);
        const code = zsg_run(source.ptr, &words, @intCast(translation.inputs.len), corpus.width, corpus.height, &result, &status, &log, log.len);
        if (code != 0) {
            std.debug.print("{s}: OpenGL failed ({d}): {s}\n{s}\n", .{ case.name, code, std.mem.sliceTo(&log, 0), source });
            return error.GpuFailed;
        }
        const faults = try corpus.compare(case.name, &machine, program, &result, &status);
        if (std.mem.eql(u8, case.name, "ints")) try std.testing.expect(faults > 0);
    }
}
