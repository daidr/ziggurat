//! Translation of compiled programs into GPU source: HLSL for Direct3D 11
//! and GLSL for OpenGL. The translation runs the same register code the
//! CPU machine runs, so both draw the same pixels: every register word is
//! a `uint` variable, floats and ints are bit casts of it, and control flow
//! follows the code's jumps, calls and returns. Code without them is
//! emitted straight; other code runs as a bounded loop over its basic
//! blocks. Faults (integer overflow, division by zero, an index out of
//! range or a float that does not fit an int) end the run, as on the CPU.
//!
//! The prologue (constant initializers) is not translated: the host runs
//! it once per application with `Machine.begin` and uploads the words
//! `Translation.gather` collects, which also carry the size, scale and
//! uniforms.
//!
//! The generated code defines
//!
//!     bool zs_run(<vec2> position, <vec4> pixel, out <vec4> result)
//!
//! which returns false on a fault. `result` is the color for color and
//! layer programs and, in `.xy`, the position to read content from for a
//! distortion. The host defines, before the generated code,
//!
//!     uint zs_input(uint index)          // word `index` of `gather`
//!     <vec4> zs_sample(<vec2> position)  // layer programs only
//!
//! where <vec2> and <vec4> are `float2`/`float4` in HLSL and `vec2`/`vec4`
//! in GLSL.
const std = @import("std");
const compiler = @import("compiler.zig");
const machine_module = @import("machine.zig");
const Program = compiler.Program;
const Instruction = compiler.Instruction;
const Op = compiler.Op;

pub const Language = enum { hlsl, glsl };

/// Words the host uploads, at most this many.
pub const max_input_words = compiler.max_register_words;

pub const Translation = struct {
    allocator: std.mem.Allocator,
    /// The generated code, without the host's definitions.
    source: []u8,
    /// Registers whose words the host uploads, in `zs_input` order.
    inputs: []u16,

    pub fn deinit(self: *Translation) void {
        self.allocator.free(self.source);
        self.allocator.free(self.inputs);
        self.* = undefined;
    }
    /// Copy the words `zs_input` returns from a machine whose `begin` ran
    /// this program's prologue. `words` holds at least `inputs.len`.
    pub fn gather(self: *const Translation, machine: *const machine_module.Machine, words: []u32) void {
        for (self.inputs, 0..) |reg, i| words[i] = machine.registers[reg];
    }
};

const Range = struct { start: u32, len: u32 };

/// Words an instruction reads or writes, statically: dynamic indexing
/// covers its whole array.
const Footprint = struct {
    reads: [3]Range = .{ .{ .start = 0, .len = 0 }, .{ .start = 0, .len = 0 }, .{ .start = 0, .len = 0 } },
    write: Range = .{ .start = 0, .len = 0 },
};

fn footprint(ins: Instruction) Footprint {
    const w: u32 = ins.w;
    const one = struct {
        fn run(reg: u16, count: u32) Range {
            return .{ .start = reg, .len = count };
        }
    }.run;
    const wa: u32 = if (ins.flags & compiler.broadcast_a != 0) 1 else w;
    const wb: u32 = if (ins.flags & compiler.broadcast_b != 0) 1 else w;
    const wc: u32 = if (ins.flags & compiler.broadcast_c != 0) 1 else w;
    var f: Footprint = .{};
    switch (ins.op) {
        .halt, .fault, .jump => {},
        .mov => {
            f.reads[0] = one(ins.a, w);
            f.write = one(ins.dst, w);
        },
        .zero => f.write = one(ins.dst, ins.c),
        .splat => {
            f.reads[0] = one(ins.a, 1);
            f.write = one(ins.dst, w);
        },
        .swizzle => {
            f.reads[0] = one(ins.a, 4);
            f.write = one(ins.dst, w);
        },
        .store_swizzle => {
            f.reads[0] = one(ins.a, w);
            f.write = one(ins.dst, 4);
        },
        .load_index => {
            f.reads[0] = one(ins.a, @as(u32, ins.c) * w);
            f.reads[1] = one(ins.b, 1);
            f.write = one(ins.dst, w);
        },
        .store_index => {
            f.reads[0] = one(ins.a, w);
            f.reads[1] = one(ins.b, 1);
            f.write = one(ins.dst, @as(u32, ins.c) * w);
        },
        .jump_zero, .ret => f.reads[0] = one(ins.a, 1),
        .call => f.write = one(ins.a, 1),
        .select => {
            f.reads[0] = one(ins.a, w);
            f.reads[1] = one(ins.b, w);
            f.reads[2] = one(ins.c, 1);
            f.write = one(ins.dst, w);
        },
        .fadd, .fsub, .fmul, .fdiv, .fmod, .fmin, .fmax, .fpow, .fatan2, .fstep => {
            f.reads[0] = one(ins.a, wa);
            f.reads[1] = one(ins.b, wb);
            f.write = one(ins.dst, w);
        },
        .fclamp, .fmix, .fsmoothstep => {
            f.reads[0] = one(ins.a, wa);
            f.reads[1] = one(ins.b, wb);
            f.reads[2] = one(ins.c, wc);
            f.write = one(ins.dst, w);
        },
        .fneg, .sin, .cos, .tan, .asin, .acos, .atan, .sqrt, .inversesqrt, .exp, .log, .exp2, .log2, .fabs, .sign, .floor, .ceil, .fract, .round, .normalize => {
            f.reads[0] = one(ins.a, w);
            f.write = one(ins.dst, w);
        },
        .dot, .distance => {
            f.reads[0] = one(ins.a, w);
            f.reads[1] = one(ins.b, w);
            f.write = one(ins.dst, 1);
        },
        .length => {
            f.reads[0] = one(ins.a, w);
            f.write = one(ins.dst, 1);
        },
        .cross => {
            f.reads[0] = one(ins.a, 3);
            f.reads[1] = one(ins.b, 3);
            f.write = one(ins.dst, 3);
        },
        .mat_vec, .vec_mat => {
            f.reads[0] = one(ins.a, w * w);
            f.reads[1] = one(ins.b, w);
            f.write = one(ins.dst, w);
        },
        .mat_mat => {
            f.reads[0] = one(ins.a, w * w);
            f.reads[1] = one(ins.b, w * w);
            f.write = one(ins.dst, w * w);
        },
        .iadd, .isub, .imul, .idiv, .imod, .imin, .imax, .flt, .fle, .ilt, .ile, .ieq, .ine, .band, .bor => {
            f.reads[0] = one(ins.a, 1);
            f.reads[1] = one(ins.b, 1);
            f.write = one(ins.dst, 1);
        },
        .feq, .fne => {
            f.reads[0] = one(ins.a, @max(w, 1));
            f.reads[1] = one(ins.b, @max(w, 1));
            f.write = one(ins.dst, 1);
        },
        .ineg, .iabs, .bnot, .itof, .ftoi => {
            f.reads[0] = one(ins.a, 1);
            f.write = one(ins.dst, 1);
        },
        .sample => {
            f.reads[0] = one(ins.a, 2);
            f.write = one(ins.dst, 4);
        },
    }
    return f;
}

fn endsBlock(op: Op) bool {
    return switch (op) {
        .halt, .fault, .jump, .jump_zero, .call, .ret => true,
        else => false,
    };
}

const Emitter = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    language: Language,
    program: *const Program,

    fn print(self: *Emitter, comptime format: []const u8, args: anytype) !void {
        try self.out.print(self.gpa, format, args);
    }
    fn write(self: *Emitter, text: []const u8) !void {
        try self.out.appendSlice(self.gpa, text);
    }
    /// Element `k` of an operand that may broadcast its first word.
    fn at(reg: u16, k: usize, broadcast: bool) usize {
        return if (broadcast) reg else reg + k;
    }

    /// One instruction that does not change control flow.
    fn instruction(self: *Emitter, ins: Instruction, indent: []const u8) !void {
        const w: usize = ins.w;
        const ba = ins.flags & compiler.broadcast_a != 0;
        const bb = ins.flags & compiler.broadcast_b != 0;
        const bc = ins.flags & compiler.broadcast_c != 0;
        const a = ins.a;
        const b = ins.b;
        const c = ins.c;
        const d = ins.dst;
        // Every result is computed into t* before any register is written,
        // so overlapping operands read their old values.
        try self.print("{s}{{ // {s}\n", .{ indent, @tagName(ins.op) });
        switch (ins.op) {
            .mov => {
                for (0..w) |k| try self.print("{s}  uint t{d} = r{d};\n", .{ indent, k, a + k });
                for (0..w) |k| try self.print("{s}  r{d} = t{d};\n", .{ indent, d + k, k });
            },
            .zero => for (0..c) |k| try self.print("{s}  r{d} = 0u;\n", .{ indent, d + k }),
            .splat => for (0..w) |k| try self.print("{s}  r{d} = r{d};\n", .{ indent, d + k, a }),
            .swizzle => {
                for (0..w) |k| try self.print("{s}  uint t{d} = r{d};\n", .{ indent, k, a + ((b >> @intCast(2 * k)) & 3) });
                for (0..w) |k| try self.print("{s}  r{d} = t{d};\n", .{ indent, d + k, k });
            },
            .store_swizzle => {
                for (0..w) |k| try self.print("{s}  uint t{d} = r{d};\n", .{ indent, k, a + k });
                for (0..w) |k| try self.print("{s}  r{d} = t{d};\n", .{ indent, d + ((b >> @intCast(2 * k)) & 3), k });
            },
            .load_index, .store_index => {
                try self.print("{s}  int index = ZI(r{d});\n", .{ indent, b });
                try self.print("{s}  if (index < 0 || index >= {d}) return false;\n", .{ indent, c });
                for (0..w) |k| try self.print("{s}  uint t{d} = 0u;\n", .{ indent, k });
                if (ins.op == .load_index) {
                    for (0..c) |e| {
                        try self.print("{s}  if (index == {d}) {{", .{ indent, e });
                        for (0..w) |k| try self.print(" t{d} = r{d};", .{ k, a + e * w + k });
                        try self.write(" }\n");
                    }
                    for (0..w) |k| try self.print("{s}  r{d} = t{d};\n", .{ indent, d + k, k });
                } else {
                    for (0..w) |k| try self.print("{s}  t{d} = r{d};\n", .{ indent, k, a + k });
                    for (0..c) |e| {
                        try self.print("{s}  if (index == {d}) {{", .{ indent, e });
                        for (0..w) |k| try self.print(" r{d} = t{d};", .{ d + e * w + k, k });
                        try self.write(" }\n");
                    }
                }
            },
            .select => {
                for (0..w) |k| try self.print("{s}  uint t{d} = r{d} != 0u ? r{d} : r{d};\n", .{ indent, k, c, a + k, b + k });
                for (0..w) |k| try self.print("{s}  r{d} = t{d};\n", .{ indent, d + k, k });
            },
            .fadd, .fsub, .fmul, .fdiv, .fmod, .fmin, .fmax, .fpow, .fatan2, .fstep => {
                for (0..w) |k| {
                    const x = at(a, k, ba);
                    const y = at(b, k, bb);
                    try self.print("{s}  float x{d} = ZF(r{d}); float y{d} = ZF(r{d});\n", .{ indent, k, x, k, y });
                    try self.print("{s}  float t{d} = ", .{ indent, k });
                    switch (ins.op) {
                        .fadd => try self.print("x{d} + y{d}", .{ k, k }),
                        .fsub => try self.print("x{d} - y{d}", .{ k, k }),
                        .fmul => try self.print("x{d} * y{d}", .{ k, k }),
                        .fdiv => try self.print("x{d} / y{d}", .{ k, k }),
                        .fmod => try self.print("x{d} - y{d} * floor(x{d} / y{d})", .{ k, k, k, k }),
                        .fmin => try self.print("min(x{d}, y{d})", .{ k, k }),
                        .fmax => try self.print("max(x{d}, y{d})", .{ k, k }),
                        .fpow => try self.print("zs_pow(x{d}, y{d})", .{ k, k }),
                        .fatan2 => try self.print("zs_atan2(x{d}, y{d})", .{ k, k }),
                        else => try self.print("(y{d} < x{d}) ? 0.0 : 1.0", .{ k, k }),
                    }
                    try self.write(";\n");
                }
                for (0..w) |k| try self.print("{s}  r{d} = ZUF(t{d});\n", .{ indent, d + k, k });
            },
            .fneg => for (0..w) |k| try self.print("{s}  r{d} = ZUF(-ZF(r{d}));\n", .{ indent, d + k, a + k }),
            .fclamp => {
                for (0..w) |k| try self.print("{s}  float t{d} = min(max(ZF(r{d}), ZF(r{d})), ZF(r{d}));\n", .{ indent, k, a + k, at(b, k, bb), at(c, k, bc) });
                for (0..w) |k| try self.print("{s}  r{d} = ZUF(t{d});\n", .{ indent, d + k, k });
            },
            .fmix => {
                for (0..w) |k| try self.print("{s}  float x{d} = ZF(r{d}); float t{d} = x{d} + (ZF(r{d}) - x{d}) * ZF(r{d});\n", .{ indent, k, a + k, k, k, b + k, k, at(c, k, bc) });
                for (0..w) |k| try self.print("{s}  r{d} = ZUF(t{d});\n", .{ indent, d + k, k });
            },
            .fsmoothstep => {
                for (0..w) |k| {
                    try self.print("{s}  float e{d} = ZF(r{d}); float s{d} = min(max((ZF(r{d}) - e{d}) / (ZF(r{d}) - e{d}), 0.0), 1.0);\n", .{ indent, k, at(a, k, ba), k, c + k, k, at(b, k, bb), k });
                    try self.print("{s}  float t{d} = s{d} * s{d} * (3.0 - 2.0 * s{d});\n", .{ indent, k, k, k, k });
                }
                for (0..w) |k| try self.print("{s}  r{d} = ZUF(t{d});\n", .{ indent, d + k, k });
            },
            .sin, .cos, .tan, .asin, .acos, .atan, .sqrt, .inversesqrt, .exp, .log, .exp2, .log2, .fabs, .sign, .floor, .ceil, .fract, .round => {
                for (0..w) |k| {
                    try self.print("{s}  float x{d} = ZF(r{d}); float t{d} = ", .{ indent, k, a + k, k });
                    switch (ins.op) {
                        .sin, .cos, .tan, .asin, .acos, .atan, .sqrt, .exp, .log, .exp2, .log2, .floor, .ceil => try self.print("{s}(x{d})", .{ @tagName(ins.op), k }),
                        .inversesqrt => try self.print("1.0 / sqrt(x{d})", .{k}),
                        .fabs => try self.print("abs(x{d})", .{k}),
                        .sign => try self.print("x{d} > 0.0 ? 1.0 : (x{d} < 0.0 ? -1.0 : 0.0)", .{ k, k }),
                        .fract => try self.print("x{d} - floor(x{d})", .{ k, k }),
                        else => try self.print("zs_round(x{d})", .{k}),
                    }
                    try self.write(";\n");
                }
                for (0..w) |k| try self.print("{s}  r{d} = ZUF(t{d});\n", .{ indent, d + k, k });
            },
            .dot, .length, .distance => {
                try self.print("{s}  float sum = 0.0;\n", .{indent});
                for (0..w) |k| switch (ins.op) {
                    .dot => try self.print("{s}  sum += ZF(r{d}) * ZF(r{d});\n", .{ indent, a + k, b + k }),
                    .length => try self.print("{s}  sum += ZF(r{d}) * ZF(r{d});\n", .{ indent, a + k, a + k }),
                    else => try self.print("{s}  {{ float e = ZF(r{d}) - ZF(r{d}); sum += e * e; }}\n", .{ indent, a + k, b + k }),
                };
                try self.print("{s}  r{d} = ZUF({s});\n", .{ indent, d, if (ins.op == .dot) "sum" else "sqrt(sum)" });
            },
            .normalize => {
                try self.print("{s}  float sum = 0.0;\n", .{indent});
                for (0..w) |k| try self.print("{s}  sum += ZF(r{d}) * ZF(r{d});\n", .{ indent, a + k, a + k });
                try self.print("{s}  float inv = 1.0 / sqrt(sum);\n", .{indent});
                for (0..w) |k| try self.print("{s}  float t{d} = ZF(r{d}) * inv;\n", .{ indent, k, a + k });
                for (0..w) |k| try self.print("{s}  r{d} = ZUF(t{d});\n", .{ indent, d + k, k });
            },
            .cross => {
                try self.print("{s}  float ax = ZF(r{d}), ay = ZF(r{d}), az = ZF(r{d}), bx = ZF(r{d}), by = ZF(r{d}), bz = ZF(r{d});\n", .{ indent, a, a + 1, a + 2, b, b + 1, b + 2 });
                try self.print("{s}  r{d} = ZUF(ay * bz - az * by); r{d} = ZUF(az * bx - ax * bz); r{d} = ZUF(ax * by - ay * bx);\n", .{ indent, d, d + 1, d + 2 });
            },
            .mat_vec, .vec_mat, .mat_mat => {
                const n = w;
                const len: usize = if (ins.op == .mat_mat) n * n else n;
                for (0..len) |slot| {
                    try self.print("{s}  float t{d} = 0.0", .{ indent, slot });
                    switch (ins.op) {
                        .mat_vec => for (0..n) |col| try self.print(" + ZF(r{d}) * ZF(r{d})", .{ a + col * n + slot, b + col }),
                        .vec_mat => for (0..n) |r| try self.print(" + ZF(r{d}) * ZF(r{d})", .{ b + r, a + slot * n + r }),
                        else => {
                            const col = slot / n;
                            const r = slot % n;
                            for (0..n) |k| try self.print(" + ZF(r{d}) * ZF(r{d})", .{ a + k * n + r, b + col * n + k });
                        },
                    }
                    try self.write(";\n");
                }
                for (0..len) |slot| try self.print("{s}  r{d} = ZUF(t{d});\n", .{ indent, d + slot, slot });
            },
            .iadd, .isub, .imul, .idiv, .imod, .imin, .imax => {
                try self.print("{s}  uint ux = r{d}; uint uy = r{d}; int x = ZI(ux); int y = ZI(uy);\n", .{ indent, a, b });
                switch (ins.op) {
                    .iadd => try self.print("{s}  uint s = ux + uy; if ((((ux ^ s) & (uy ^ s)) >> 31) != 0u) return false; r{d} = s;\n", .{ indent, d }),
                    .isub => try self.print("{s}  uint s = ux - uy; if ((((ux ^ uy) & (ux ^ s)) >> 31) != 0u) return false; r{d} = s;\n", .{ indent, d }),
                    .imul => try self.print("{s}  uint p = ux * uy; if (x == -1 ? uy == 0x80000000u : (x != 0 && zs_div(ZI(p), x) != y)) return false; r{d} = p;\n", .{ indent, d }),
                    .idiv => try self.print("{s}  if (y == 0 || (ux == 0x80000000u && y == -1)) return false; r{d} = ZUI(zs_div(x, y));\n", .{ indent, d }),
                    .imod => try self.print("{s}  if (y == 0 || (ux == 0x80000000u && y == -1)) return false; r{d} = ZUI(x - zs_div(x, y) * y);\n", .{ indent, d }),
                    .imin => try self.print("{s}  r{d} = ZUI(min(x, y));\n", .{ indent, d }),
                    else => try self.print("{s}  r{d} = ZUI(max(x, y));\n", .{ indent, d }),
                }
            },
            .ineg, .iabs => {
                try self.print("{s}  if (r{d} == 0x80000000u) return false;\n", .{ indent, a });
                if (ins.op == .ineg)
                    try self.print("{s}  r{d} = ZUI(-ZI(r{d}));\n", .{ indent, d, a })
                else
                    try self.print("{s}  r{d} = ZUI(abs(ZI(r{d})));\n", .{ indent, d, a });
            },
            .flt => try self.print("{s}  r{d} = ZF(r{d}) < ZF(r{d}) ? 1u : 0u;\n", .{ indent, d, a, b }),
            .fle => try self.print("{s}  r{d} = ZF(r{d}) <= ZF(r{d}) ? 1u : 0u;\n", .{ indent, d, a, b }),
            .feq, .fne => {
                try self.print("{s}  bool same = true;\n", .{indent});
                for (0..@max(w, 1)) |k| try self.print("{s}  if (ZF(r{d}) != ZF(r{d})) same = false;\n", .{ indent, a + k, b + k });
                try self.print("{s}  r{d} = same == {s} ? 1u : 0u;\n", .{ indent, d, if (ins.op == .feq) "true" else "false" });
            },
            .ilt => try self.print("{s}  r{d} = ZI(r{d}) < ZI(r{d}) ? 1u : 0u;\n", .{ indent, d, a, b }),
            .ile => try self.print("{s}  r{d} = ZI(r{d}) <= ZI(r{d}) ? 1u : 0u;\n", .{ indent, d, a, b }),
            .ieq => try self.print("{s}  r{d} = r{d} == r{d} ? 1u : 0u;\n", .{ indent, d, a, b }),
            .ine => try self.print("{s}  r{d} = r{d} != r{d} ? 1u : 0u;\n", .{ indent, d, a, b }),
            .bnot => try self.print("{s}  r{d} = r{d} == 0u ? 1u : 0u;\n", .{ indent, d, a }),
            .band => try self.print("{s}  r{d} = (r{d} != 0u && r{d} != 0u) ? 1u : 0u;\n", .{ indent, d, a, b }),
            .bor => try self.print("{s}  r{d} = (r{d} != 0u || r{d} != 0u) ? 1u : 0u;\n", .{ indent, d, a, b }),
            .itof => try self.print("{s}  r{d} = ZUF(float(ZI(r{d})));\n", .{ indent, d, a }),
            .ftoi => {
                try self.print("{s}  float x = ZF(r{d});\n", .{ indent, a });
                try self.print("{s}  if (!zs_finite(x) || x >= 2147483648.0 || x < -2147483648.0) return false;\n", .{indent});
                try self.print("{s}  r{d} = ZUI(int(x));\n", .{ indent, d });
            },
            .sample => {
                try self.print("{s}  {s}4 s = zs_sample({s}2(ZF(r{d}), ZF(r{d})));\n", .{ indent, self.vec(), self.vec(), a, a + 1 });
                try self.print("{s}  r{d} = ZUF(s.x); r{d} = ZUF(s.y); r{d} = ZUF(s.z); r{d} = ZUF(s.w);\n", .{ indent, d, d + 1, d + 2, d + 3 });
            },
            .halt, .fault, .jump, .jump_zero, .call, .ret => unreachable,
        }
        try self.print("{s}}}\n", .{indent});
    }
    fn vec(self: *const Emitter) []const u8 {
        return if (self.language == .hlsl) "float" else "vec";
    }
};

fn prelude(language: Language) []const u8 {
    return switch (language) {
        .hlsl =>
        \\#define ZF(x) asfloat(x)
        \\#define ZUF(x) asuint(x)
        \\#define ZI(x) asint(x)
        \\#define ZUI(x) asuint(x)
        \\bool zs_finite(float x) { return !isnan(x) && !isinf(x); }
        \\float zs_atan2(float y, float x) { return atan2(y, x); }
        \\
        ,
        .glsl =>
        \\#define ZF(x) uintBitsToFloat(x)
        \\#define ZUF(x) floatBitsToUint(x)
        \\#define ZI(x) int(x)
        \\#define ZUI(x) uint(x)
        \\bool zs_finite(float x) { return !isnan(x) && !isinf(x); }
        \\float zs_atan2(float y, float x) {
        \\    if (x == 0.0 && y == 0.0) return (floatBitsToUint(x) >> 31) != 0u ? (y < 0.0 || (floatBitsToUint(y) >> 31) != 0u ? -3.14159265 : 3.14159265) : y;
        \\    return atan(y, x);
        \\}
        \\
        ,
    };
}
const common_prelude =
    \\float zs_pow(float x, float y) {
    \\    if (y == 0.0) return 1.0;
    \\    if (x < 0.0 && y == floor(y)) {
    \\        float r = pow(-x, y);
    \\        return y - 2.0 * floor(y / 2.0) != 0.0 ? -r : r;
    \\    }
    \\    return pow(x, y);
    \\}
    \\float zs_round(float x) { return x < 0.0 ? -floor(-x + 0.5) : floor(x + 0.5); }
    \\int zs_div(int x, int y) {
    \\    uint q = uint(abs(x)) / uint(abs(y));
    \\    return (x < 0) != (y < 0) ? -int(q) : int(q);
    \\}
    \\
;

/// Translate `program` for `language`. The result owns its memory.
pub fn translate(gpa: std.mem.Allocator, program: *const Program, language: Language) error{ OutOfMemory, UnsupportedProgram }!Translation {
    const code = program.code;
    // Reachable code from the entry, its block leaders and the registers
    // it touches.
    const reachable = try gpa.alloc(bool, code.len);
    defer gpa.free(reachable);
    @memset(reachable, false);
    const leader = try gpa.alloc(bool, code.len + 1);
    defer gpa.free(leader);
    @memset(leader, false);
    var used = try std.DynamicBitSetUnmanaged.initEmpty(gpa, compiler.max_register_words);
    defer used.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, program.entry);
    leader[program.entry] = true;
    var branches = false;
    while (stack.pop()) |start| {
        var pc: u32 = start;
        while (pc < code.len and !reachable[pc]) {
            reachable[pc] = true;
            const ins = code[pc];
            const f = footprint(ins);
            for (f.reads) |range| if (range.len != 0) {
                if (range.start + range.len > compiler.max_register_words) return error.UnsupportedProgram;
                used.setRangeValue(.{ .start = range.start, .end = range.start + range.len }, true);
            };
            if (f.write.len != 0) {
                if (f.write.start + f.write.len > compiler.max_register_words) return error.UnsupportedProgram;
                used.setRangeValue(.{ .start = f.write.start, .end = f.write.start + f.write.len }, true);
            }
            pc += 1;
            switch (ins.op) {
                .halt, .fault, .ret => {
                    leader[pc] = true;
                    break;
                },
                .jump => {
                    branches = true;
                    if (ins.dst >= code.len) return error.UnsupportedProgram;
                    leader[ins.dst] = true;
                    leader[pc] = true;
                    try stack.append(gpa, ins.dst);
                    break;
                },
                .jump_zero, .call => {
                    branches = true;
                    if (ins.dst >= code.len) return error.UnsupportedProgram;
                    leader[ins.dst] = true;
                    leader[pc] = true;
                    try stack.append(gpa, ins.dst);
                    try stack.append(gpa, pc);
                    break;
                },
                else => {},
            }
        }
    }
    for ([_]Range{
        .{ .start = program.position_register, .len = 2 },
        .{ .start = program.pixel_register, .len = if (program.kind == .color) 4 else 0 },
        .{ .start = program.result_register, .len = if (program.kind == .distortion) 2 else 4 },
        .{ .start = program.entry_slot, .len = 1 },
    }) |range| {
        if (range.start + range.len > compiler.max_register_words) return error.UnsupportedProgram;
        used.setRangeValue(.{ .start = range.start, .end = range.start + range.len }, true);
    }
    // What the prologue computes, which the host runs.
    var computed = try std.DynamicBitSetUnmanaged.initEmpty(gpa, compiler.max_register_words);
    defer computed.deinit(gpa);
    for (code[0..program.prologue_end]) |ins| {
        const write = footprint(ins).write;
        if (write.len != 0 and write.start + write.len <= compiler.max_register_words) computed.setRangeValue(.{ .start = write.start, .end = write.start + write.len }, true);
    }
    // Words the host uploads: size, scale, uniforms and the prologue's
    // results the code reads.
    var inputs: std.ArrayList(u16) = .empty;
    errdefer inputs.deinit(gpa);
    const constants_end: usize = program.image.len;
    const register_end: usize = @max(program.register_words, constants_end);
    var reg: usize = 0;
    while (reg < register_end) : (reg += 1) {
        const builtin = reg < compiler.uniform_base + program.uniform_words;
        const constant = reg >= compiler.constant_base and reg < constants_end;
        if (builtin or (!constant and used.isSet(reg) and computed.isSet(reg))) try inputs.append(gpa, @intCast(reg));
    }

    var e: Emitter = .{ .gpa = gpa, .language = language, .program = program };
    errdefer e.out.deinit(gpa);
    try e.write(prelude(language));
    try e.write(common_prelude);
    const v = e.vec();
    try e.print("bool zs_run({s}2 position, {s}4 pixel, out {s}4 result) {{\n", .{ v, v, v });
    try e.print("  result = {s}4(0.0, 0.0, 0.0, 0.0);\n", .{v});
    // Registers: constants are literals, inputs are uploaded words.
    var input_index: usize = 0;
    reg = 0;
    while (reg < register_end) : (reg += 1) {
        const is_input = input_index < inputs.items.len and inputs.items[input_index] == reg;
        if (is_input) {
            try e.print("  uint r{d} = zs_input({d}u);\n", .{ reg, input_index });
            input_index += 1;
        } else if (reg >= compiler.constant_base and reg < constants_end) {
            if (used.isSet(reg)) try e.print("  uint r{d} = {d}u;\n", .{ reg, program.image[reg] });
        } else if (used.isSet(reg)) try e.print("  uint r{d} = 0u;\n", .{reg});
    }
    // Arguments.
    try e.print("  r{d} = ZUF(position.x); r{d} = ZUF(position.y);\n", .{ program.position_register, program.position_register + 1 });
    if (program.kind == .color) try e.print("  r{d} = ZUF(pixel.x); r{d} = ZUF(pixel.y); r{d} = ZUF(pixel.z); r{d} = ZUF(pixel.w);\n", .{ program.pixel_register, program.pixel_register + 1, program.pixel_register + 2, program.pixel_register + 3 });
    try e.print("  r{d} = 0xFFFFFFFFu;\n", .{program.entry_slot});
    if (!branches) {
        // One straight block: the entry runs to its return.
        var pc: usize = program.entry;
        while (pc < code.len) : (pc += 1) {
            const ins = code[pc];
            switch (ins.op) {
                .halt, .ret => break,
                .fault => {
                    try e.write("  return false;\n");
                    break;
                },
                else => try e.instruction(ins, "  "),
            }
        }
    } else {
        // A loop over basic blocks, bounded by the program's step count.
        // The blocks are a flat run of ifs rather than a switch, because the
        // Direct3D compiler fails on assignments in switch cases inside a loop.
        try e.print("  uint pc = {d}u;\n", .{program.entry});
        if (language == .hlsl) try e.write("  [loop]\n");
        try e.print("  for (uint guard = 0u; guard <= {d}u; guard++) {{\n", .{@as(u64, program.max_steps) + 1});
        try e.write("    if (pc == 0xFFFFFFFFu) break;\n");
        var pc: usize = 0;
        while (pc < code.len) : (pc += 1) {
            if (!reachable[pc] or !leader[pc]) continue;
            try e.print("    if (pc == {d}u) {{\n", .{pc});
            var at_pc = pc;
            while (true) : (at_pc += 1) {
                const ins = code[at_pc];
                switch (ins.op) {
                    .halt => {
                        try e.write("      pc = 0xFFFFFFFFu; continue;\n");
                        break;
                    },
                    .fault => {
                        try e.write("      return false;\n");
                        break;
                    },
                    .jump => {
                        try e.print("      pc = {d}u; continue;\n", .{ins.dst});
                        break;
                    },
                    .jump_zero => {
                        try e.print("      pc = r{d} == 0u ? {d}u : {d}u; continue;\n", .{ ins.a, ins.dst, at_pc + 1 });
                        break;
                    },
                    .call => {
                        try e.print("      r{d} = {d}u; pc = {d}u; continue;\n", .{ ins.a, at_pc + 1, ins.dst });
                        break;
                    },
                    .ret => {
                        try e.print("      pc = r{d}; continue;\n", .{ins.a});
                        break;
                    },
                    else => try e.instruction(ins, "      "),
                }
                if (at_pc + 1 >= code.len) {
                    try e.write("      return false;\n");
                    break;
                }
                if (leader[at_pc + 1]) {
                    try e.print("      pc = {d}u; continue;\n", .{at_pc + 1});
                    break;
                }
            }
            try e.write("    }\n");
        }
        try e.write("    return false;\n");
        try e.write("  }\n");
        try e.write("  if (pc != 0xFFFFFFFFu) return false;\n");
    }
    const out = program.result_register;
    if (program.kind == .distortion)
        try e.print("  result = {s}4(ZF(r{d}), ZF(r{d}), 0.0, 0.0);\n", .{ v, out, out + 1 })
    else
        try e.print("  result = {s}4(ZF(r{d}), ZF(r{d}), ZF(r{d}), ZF(r{d}));\n", .{ v, out, out + 1, out + 2, out + 3 });
    try e.write("  return true;\n}\n");
    const source = try e.out.toOwnedSlice(gpa);
    errdefer gpa.free(source);
    return .{ .allocator = gpa, .source = source, .inputs = try inputs.toOwnedSlice(gpa) };
}

test "translation uploads size, scale, uniforms and prologue results" {
    var diagnostic: compiler.Diagnostic = .{};
    const program = try compiler.compile(std.testing.allocator,
        \\uniform float amount;
        \\const float twice = amount * 2.0;
        \\float half(float x) { return x * 0.5; }
        \\vec4 color(vec2 position, vec4 pixel) {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 3; i++) sum += half(twice);
        \\    return pixel * sum;
        \\}
    , .{}, &diagnostic);
    defer program.destroy();
    for ([_]Language{ .hlsl, .glsl }) |language| {
        var translation = try translate(std.testing.allocator, program, language);
        defer translation.deinit();
        // size (2), scale and one uniform, then what the prologue wrote,
        // the constant `twice` among it.
        try std.testing.expect(translation.inputs.len >= 5);
        try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3 }, translation.inputs[0..4]);
        try std.testing.expect(std.mem.indexOf(u8, translation.source, "bool zs_run(") != null);
        // Calls and the loop run as basic blocks.
        try std.testing.expect(std.mem.indexOf(u8, translation.source, "if (pc == ") != null);
        var values = machine_module.Values.init(program);
        try values.set(program.uniform("amount").?, @as(f32, 1.5));
        var m: machine_module.Machine = .{};
        try m.begin(program, &values, .{ 8, 4 }, 2);
        var words: [max_input_words]u32 = undefined;
        translation.gather(&m, &words);
        try std.testing.expectEqual(@as(f32, 8), @as(f32, @bitCast(words[0])));
        try std.testing.expectEqual(@as(f32, 2), @as(f32, @bitCast(words[2])));
        try std.testing.expectEqual(@as(f32, 1.5), @as(f32, @bitCast(words[3])));
        var found = false;
        for (words[4..translation.inputs.len]) |word| found = found or @as(f32, @bitCast(word)) == 3;
        try std.testing.expect(found);
    }
    // Straight code needs no block loop.
    const straight = try compiler.compile(std.testing.allocator, "vec2 distort(vec2 p) { return p * 2.0; }", .{}, &diagnostic);
    defer straight.destroy();
    var translation = try translate(std.testing.allocator, straight, .glsl);
    defer translation.deinit();
    try std.testing.expect(std.mem.indexOf(u8, translation.source, "if (pc == ") == null);
}
