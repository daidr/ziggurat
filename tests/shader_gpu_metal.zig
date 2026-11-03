//! Translated shader programs compute on Metal what the CPU machine
//! computes, pixel for pixel, faults included.
const std = @import("std");
const shader = @import("ziggurat_shader");
const corpus = @import("shader_gpu_corpus.zig");

extern fn zsm_init(log: [*]u8, log_len: usize) c_int;
extern fn zsm_run(source: [*:0]const u8, words: [*]const u32, word_count: u32, width: u32, height: u32, result: [*]f32, status: [*]f32, log: [*]u8, log_len: usize) c_int;

fn host(allocator: std.mem.Allocator, translation: *const shader.gpu.Translation) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator,
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\#define ZS_PARAMS constant uint4 *zs_words,
        \\#define ZS_PASS zs_words,
        \\uint zs_input(ZS_PARAMS uint i) {{ return zs_words[i >> 2u][i & 3u]; }}
        \\float4 zs_sample(ZS_PARAMS float2 p) {{ float a = p.x * 0.13; float b = p.y * 0.07; return float4(a - floor(a), b - floor(b), 0.5, 1.0); }}
        \\{s}
        \\kernel void zs_test(uint2 at [[thread_position_in_grid]], constant uint4 *zs_words [[buffer(0)]], device float4 *results [[buffer(1)]], device float4 *statuses [[buffer(2)]], constant uint &width [[buffer(3)]]) {{
        \\    float x = float(at.x);
        \\    float y = float(at.y);
        \\    float2 position = float2(x * 0.37 - 3.0, y * 0.53 - 2.0);
        \\    float4 pixel = float4(x / {d}.0, y / {d}.0, 0.25, 0.75);
        \\    float4 result = float4(0.0);
        \\    bool ok = zs_run(ZS_PASS position, pixel, result);
        \\    results[at.y * width + at.x] = result;
        \\    statuses[at.y * width + at.x] = float4(ok ? 1.0 : 0.0);
        \\}}
        \\
    , .{ translation.source, corpus.width, corpus.height }, 0);
}

test "translated programs match the CPU machine on Metal" {
    const allocator = std.testing.allocator;
    var log: [4096]u8 = @splat(0);
    if (zsm_init(&log, log.len) != 0) {
        std.debug.print("Metal unavailable: {s}\n", .{std.mem.sliceTo(&log, 0)});
        return error.SkipZigTest;
    }
    for (corpus.cases) |case| {
        var machine: shader.Machine = .{};
        const program = try corpus.prepare(allocator, case, &machine);
        defer program.destroy();
        var translation = try shader.gpu.translate(allocator, program, .msl);
        defer translation.deinit();
        var words: [shader.gpu.max_input_words]u32 = undefined;
        translation.gather(&machine, &words);
        const source = try host(allocator, &translation);
        defer allocator.free(source);
        var result: [corpus.width * corpus.height * 4]f32 = undefined;
        var status: [corpus.width * corpus.height * 4]f32 = undefined;
        @memset(&log, 0);
        const code = zsm_run(source.ptr, &words, @intCast(translation.inputs.len), corpus.width, corpus.height, &result, &status, &log, log.len);
        if (code != 0) {
            std.debug.print("{s}: Metal failed ({d}): {s}\n{s}\n", .{ case.name, code, std.mem.sliceTo(&log, 0), source });
            return error.GpuFailed;
        }
        const faults = try corpus.compare(case.name, &machine, program, &result, &status);
        if (std.mem.eql(u8, case.name, "ints")) try std.testing.expect(faults > 0);
    }
}
