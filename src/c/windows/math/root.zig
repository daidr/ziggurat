//! Strong definitions of the C transcendental math functions, taken from
//! Zig's own compiler-rt implementation.
//!
//! With the self-hosted backend and libc, Windows Debug artifacts lower
//! `@sin`, `@exp` and friends to calls of the C symbols, and the self-hosted
//! COFF linker binds them to the UCRT imports instead of compiler-rt's weak
//! definitions. UCRT's results can differ in the last bit (for example
//! sin(-pi/4)), which breaks pixel-exact tests and makes Windows Debug differ
//! from the LLVM builds. build.zig compiles this file, next to a copy of
//! lib/compiler_rt, into a static library linked ahead of libc.
const sin = @import("compiler_rt/sin.zig");
const cos = @import("compiler_rt/cos.zig");
const tan = @import("compiler_rt/tan.zig");
const exp = @import("compiler_rt/exp.zig");
const exp2 = @import("compiler_rt/exp2.zig");
const log = @import("compiler_rt/log.zig");
const log2 = @import("compiler_rt/log2.zig");
const log10 = @import("compiler_rt/log10.zig");

comptime {
    for (.{
        .{ "sin", sin.sin_f64, sin.sin_f32 },
        .{ "cos", cos.cos_f64, cos.cos_f32 },
        .{ "tan", tan.tan_f64, tan.tan_f32 },
        .{ "exp", exp.exp_f64, exp.exp_f32 },
        .{ "exp2", exp2.exp2_f64, exp2.exp2_f32 },
        .{ "log", log.log_f64, log.log_f32 },
        .{ "log2", log2.log2_f64, log2.log2_f32 },
        .{ "log10", log10.log10_f64, log10.log10_f32 },
    }) |entry| {
        @export(&C(entry[1]).call, .{ .name = entry[0], .visibility = .hidden });
        @export(&C(entry[2]).call, .{ .name = entry[0] ++ "f", .visibility = .hidden });
    }
}

fn C(comptime function: anytype) type {
    const T = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    return struct {
        fn call(x: T) callconv(.c) T {
            return function(x);
        }
    };
}
