//! A small, bounded shading language for element effects. Source text is
//! compiled explicitly into an immutable Program that owns everything it
//! needs; nothing borrows the source afterwards. Programs have no recursion,
//! no unbounded loops and a statically known worst-case step count, so every
//! run on the CPU machine is bounded before it starts.
const std = @import("std");
const compiler = @import("compiler.zig");
const machine = @import("machine.zig");

pub const Type = compiler.Type;
pub const Kind = compiler.Kind;
pub const Op = compiler.Op;
pub const Instruction = compiler.Instruction;
pub const Diagnostic = compiler.Diagnostic;
pub const Options = compiler.Options;
pub const Program = compiler.Program;
pub const Uniform = compiler.Uniform;
pub const compile = compiler.compile;
pub const Values = machine.Values;
pub const Machine = machine.Machine;
pub const Sampler = machine.Sampler;
pub const Fault = machine.Fault;
pub const max_uniform_words = compiler.max_uniform_words;
pub const max_register_words = compiler.max_register_words;
/// Translation into HLSL and GLSL for GPU execution.
pub const gpu = @import("gpu.zig");

test {
    _ = @import("tests.zig");
    _ = gpu;
}
