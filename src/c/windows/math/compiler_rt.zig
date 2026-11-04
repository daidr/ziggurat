//! Just enough of Zig's lib/compiler_rt.zig for its transcendental math files.
//! build.zig copies lib/compiler_rt next to this file; see root.zig.
const std = @import("std");
pub inline fn symbol(comptime func: *const anyopaque, comptime name: []const u8) void {
    _ = func;
    _ = name;
}
pub const want_float_exceptions = true;
fn Same(comptime T: type) type {
    return struct {
        pub const Abi = T;
        pub inline fn toAbi(value: T) Abi {
            return value;
        }
        pub inline fn fromAbi(value: Abi) T {
            return value;
        }
    };
}
pub const @"f16" = Same(f16);
pub const @"f32" = Same(f32);
pub const @"f64" = Same(f64);
pub const @"f80" = Same(f80);
pub const @"f128" = Same(f128);
