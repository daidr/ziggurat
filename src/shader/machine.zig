//! CPU execution of compiled programs. A Machine is caller-owned scratch: it
//! holds the register file for one program at a time, never allocates and
//! never runs more steps than the program's static bound.
const std = @import("std");
const compiler = @import("compiler.zig");
const Program = compiler.Program;
const Uniform = compiler.Uniform;
const Op = compiler.Op;

/// A run stopped: integer overflow or division by zero, an index out of
/// range, a float that does not fit an int, or a function that ended without
/// returning.
pub const Fault = error{ShaderFault};

/// Reads premultiplied RGBA content at a position, for layer programs.
pub const Sampler = struct {
    context: *const anyopaque,
    function: *const fn (context: *const anyopaque, x: f32, y: f32) [4]f32,
    pub fn sample(self: Sampler, x: f32, y: f32) [4]f32 {
        return self.function(self.context, x, y);
    }
};

/// Uniform values for one program. Setting a value copies it, so a recorded
/// copy of this buffer is unaffected by later changes.
pub const Values = struct {
    program: u64,
    len: u16,
    words: [compiler.max_uniform_words]u32 = @splat(0),

    pub fn init(program: *const Program) Values {
        return .{ .program = program.identity, .len = program.uniform_words };
    }
    /// Sets a whole uniform: `f32` for float, `i32` for int, `bool`, `[N]f32`
    /// for a vector or a column-major matrix, or a slice holding every
    /// element of an array uniform. Floats must be finite.
    pub fn set(self: *Values, uniform: Uniform, value: anytype) error{ UniformMismatch, InvalidValue }!void {
        if (uniform.program != self.program) return error.UniformMismatch;
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (info == .pointer and info.pointer.size == .slice or info == .pointer and @typeInfo(info.pointer.child) == .array) {
            if (uniform.count == 0 or value.len != uniform.count) return error.UniformMismatch;
            for (value, 0..) |element, index| try self.setElement(uniform, index, element);
            return;
        }
        if (uniform.count != 0) return error.UniformMismatch;
        try write(self.words[uniform.offset..][0..uniform.ty.words()], uniform.ty, value);
    }
    /// Sets one element of an array uniform.
    pub fn setElement(self: *Values, uniform: Uniform, index: usize, value: anytype) error{ UniformMismatch, InvalidValue }!void {
        if (uniform.program != self.program) return error.UniformMismatch;
        if (uniform.count == 0 or index >= uniform.count) return error.UniformMismatch;
        const words = uniform.ty.words();
        try write(self.words[uniform.offset + index * words ..][0..words], uniform.ty, value);
    }
    fn write(target: []u32, ty: compiler.Type, value: anytype) error{ UniformMismatch, InvalidValue }!void {
        const T = @TypeOf(value);
        switch (ty) {
            .bool => {
                if (T != bool) return error.UniformMismatch;
                target[0] = @intFromBool(value);
            },
            .int => {
                if (T != i32 and T != comptime_int) return error.UniformMismatch;
                const int: i32 = value;
                target[0] = @bitCast(int);
            },
            .float => {
                if (T != f32 and T != comptime_float and T != f64) return error.UniformMismatch;
                const float: f32 = @floatCast(value);
                if (!std.math.isFinite(float)) return error.InvalidValue;
                target[0] = @bitCast(float);
            },
            else => {
                if (@typeInfo(T) != .array or @typeInfo(T).array.child != f32 or @typeInfo(T).array.len != target.len) return error.UniformMismatch;
                for (value) |float| if (!std.math.isFinite(float)) return error.InvalidValue;
                for (value, 0..) |float, i| target[i] = @bitCast(float);
            },
        }
    }
};

pub const Machine = struct {
    registers: [compiler.max_register_words]u32 = undefined,
    program: ?*const Program = null,
    sampler: ?Sampler = null,
    /// Steps of the last run, for tests and accounting.
    steps: u64 = 0,

    /// Loads `program` with its constants, the element `size` in DIP, the
    /// pixel `scale` and `values`, then runs its constant initializers.
    pub fn begin(self: *Machine, program: *const Program, values: *const Values, size: [2]f32, scale: f32) (Fault || error{UniformMismatch})!void {
        if (values.program != program.identity or values.len != program.uniform_words) return error.UniformMismatch;
        self.program = program;
        @memcpy(self.registers[0..program.image.len], program.image);
        self.registers[compiler.size_register] = @bitCast(size[0]);
        self.registers[compiler.size_register + 1] = @bitCast(size[1]);
        self.registers[compiler.scale_register] = @bitCast(scale);
        @memcpy(self.registers[compiler.uniform_base..][0..program.uniform_words], values.words[0..program.uniform_words]);
        try self.run(0, program.prologue_steps);
    }
    pub fn color(self: *Machine, position: [2]f32, pixel: [4]f32) Fault![4]f32 {
        const program = self.program.?;
        std.debug.assert(program.kind == .color);
        self.put(program.position_register, &position);
        self.put(program.pixel_register, &pixel);
        try self.entry();
        return self.get(4, program.result_register);
    }
    pub fn distort(self: *Machine, position: [2]f32) Fault![2]f32 {
        const program = self.program.?;
        std.debug.assert(program.kind == .distortion);
        self.put(program.position_register, &position);
        try self.entry();
        return self.get(2, program.result_register);
    }
    pub fn layer(self: *Machine, position: [2]f32, sampler: Sampler) Fault![4]f32 {
        const program = self.program.?;
        std.debug.assert(program.kind == .layer);
        self.sampler = sampler;
        defer self.sampler = null;
        self.put(program.position_register, &position);
        try self.entry();
        return self.get(4, program.result_register);
    }
    fn entry(self: *Machine) Fault!void {
        const program = self.program.?;
        self.registers[program.entry_slot] = compiler.return_halt;
        try self.run(program.entry, program.max_steps);
    }
    fn put(self: *Machine, reg: u16, values: []const f32) void {
        for (values, 0..) |value, i| self.registers[reg + i] = @bitCast(value);
    }
    fn get(self: *const Machine, comptime n: usize, reg: u16) [n]f32 {
        var result: [n]f32 = undefined;
        for (0..n) |i| result[i] = @bitCast(self.registers[reg + i]);
        return result;
    }
    inline fn f(self: *const Machine, reg: usize) f32 {
        return @bitCast(self.registers[reg]);
    }
    inline fn setf(self: *Machine, reg: usize, value: f32) void {
        self.registers[reg] = @bitCast(value);
    }
    inline fn int(self: *const Machine, reg: usize) i32 {
        return @bitCast(self.registers[reg]);
    }
    inline fn setInt(self: *Machine, reg: usize, value: i32) void {
        self.registers[reg] = @bitCast(value);
    }

    fn run(self: *Machine, start: u16, limit: u64) Fault!void {
        const program = self.program.?;
        const code = program.code;
        var pc: usize = start;
        var steps: u64 = 0;
        defer self.steps = steps;
        while (true) {
            if (pc >= code.len) return error.ShaderFault;
            const ins = code[pc];
            pc += 1;
            if (ins.op != .halt) {
                steps += 1;
                // The static bound makes this unreachable for valid code.
                if (steps > limit) return error.ShaderFault;
            }
            const w: usize = ins.w;
            const dst: usize = ins.dst;
            const a: usize = ins.a;
            const b: usize = ins.b;
            const c: usize = ins.c;
            const sa: usize = if (ins.flags & compiler.broadcast_a != 0) 0 else 1;
            const sb: usize = if (ins.flags & compiler.broadcast_b != 0) 0 else 1;
            const sc: usize = if (ins.flags & compiler.broadcast_c != 0) 0 else 1;
            switch (ins.op) {
                .halt => return,
                .fault => return error.ShaderFault,
                .mov => std.mem.copyForwards(u32, self.registers[dst..][0..w], self.registers[a..][0..w]),
                .zero => @memset(self.registers[dst..][0..c], 0),
                .splat => for (0..w) |k| {
                    self.registers[dst + k] = self.registers[a];
                },
                .swizzle => {
                    var tmp: [4]u32 = undefined;
                    for (0..w) |k| tmp[k] = self.registers[a + ((b >> @intCast(2 * k)) & 3)];
                    @memcpy(self.registers[dst..][0..w], tmp[0..w]);
                },
                .store_swizzle => {
                    var tmp: [4]u32 = undefined;
                    @memcpy(tmp[0..w], self.registers[a..][0..w]);
                    for (0..w) |k| self.registers[dst + ((b >> @intCast(2 * k)) & 3)] = tmp[k];
                },
                .load_index => {
                    const index = self.int(b);
                    if (index < 0 or index >= c) return error.ShaderFault;
                    std.mem.copyForwards(u32, self.registers[dst..][0..w], self.registers[a + @as(usize, @intCast(index)) * w ..][0..w]);
                },
                .store_index => {
                    const index = self.int(b);
                    if (index < 0 or index >= c) return error.ShaderFault;
                    std.mem.copyForwards(u32, self.registers[dst + @as(usize, @intCast(index)) * w ..][0..w], self.registers[a..][0..w]);
                },
                .jump => pc = dst,
                .jump_zero => if (self.registers[a] == 0) {
                    pc = dst;
                },
                .call => {
                    self.registers[a] = @intCast(pc);
                    pc = dst;
                },
                .ret => {
                    const target = self.registers[a];
                    if (target == compiler.return_halt) return;
                    pc = target;
                },
                .select => {
                    const source = if (self.registers[c] != 0) a else b;
                    std.mem.copyForwards(u32, self.registers[dst..][0..w], self.registers[source..][0..w]);
                },
                .fadd, .fsub, .fmul, .fdiv, .fmod, .fmin, .fmax, .fpow, .fatan2, .fstep => for (0..w) |k| {
                    const x = self.f(a + k * sa);
                    const y = self.f(b + k * sb);
                    self.setf(dst + k, switch (ins.op) {
                        .fadd => x + y,
                        .fsub => x - y,
                        .fmul => x * y,
                        .fdiv => x / y,
                        .fmod => x - y * @floor(x / y),
                        .fmin => @min(x, y),
                        .fmax => @max(x, y),
                        .fpow => std.math.pow(f32, x, y),
                        .fatan2 => std.math.atan2(x, y),
                        else => if (y < x) @as(f32, 0) else 1,
                    });
                },
                .fneg => for (0..w) |k| self.setf(dst + k, -self.f(a + k)),
                .fclamp => for (0..w) |k| self.setf(dst + k, @min(@max(self.f(a + k), self.f(b + k * sb)), self.f(c + k * sc))),
                .fmix => for (0..w) |k| {
                    const x = self.f(a + k);
                    self.setf(dst + k, x + (self.f(b + k) - x) * self.f(c + k * sc));
                },
                .fsmoothstep => for (0..w) |k| {
                    const e0 = self.f(a + k * sa);
                    const e1 = self.f(b + k * sb);
                    const t = std.math.clamp((self.f(c + k) - e0) / (e1 - e0), 0, 1);
                    self.setf(dst + k, t * t * (3 - 2 * t));
                },
                .sin, .cos, .tan, .asin, .acos, .atan, .sqrt, .inversesqrt, .exp, .log, .exp2, .log2, .fabs, .sign, .floor, .ceil, .fract, .round => for (0..w) |k| {
                    const x = self.f(a + k);
                    self.setf(dst + k, switch (ins.op) {
                        .sin => @sin(x),
                        .cos => @cos(x),
                        .tan => @tan(x),
                        .asin => std.math.asin(x),
                        .acos => std.math.acos(x),
                        .atan => std.math.atan(x),
                        .sqrt => @sqrt(x),
                        .inversesqrt => 1 / @sqrt(x),
                        .exp => @exp(x),
                        .log => @log(x),
                        .exp2 => @exp2(x),
                        .log2 => @log2(x),
                        .fabs => @abs(x),
                        .sign => if (x > 0) @as(f32, 1) else if (x < 0) @as(f32, -1) else 0,
                        .floor => @floor(x),
                        .ceil => @ceil(x),
                        .fract => x - @floor(x),
                        else => @round(x),
                    });
                },
                .dot => {
                    var sum: f32 = 0;
                    for (0..w) |k| sum += self.f(a + k) * self.f(b + k);
                    self.setf(dst, sum);
                },
                .length => {
                    var sum: f32 = 0;
                    for (0..w) |k| sum += self.f(a + k) * self.f(a + k);
                    self.setf(dst, @sqrt(sum));
                },
                .distance => {
                    var sum: f32 = 0;
                    for (0..w) |k| {
                        const d = self.f(a + k) - self.f(b + k);
                        sum += d * d;
                    }
                    self.setf(dst, @sqrt(sum));
                },
                .normalize => {
                    var sum: f32 = 0;
                    for (0..w) |k| sum += self.f(a + k) * self.f(a + k);
                    const inverse = 1 / @sqrt(sum);
                    for (0..w) |k| self.setf(dst + k, self.f(a + k) * inverse);
                },
                .cross => {
                    const x = [3]f32{ self.f(a), self.f(a + 1), self.f(a + 2) };
                    const y = [3]f32{ self.f(b), self.f(b + 1), self.f(b + 2) };
                    self.setf(dst, x[1] * y[2] - x[2] * y[1]);
                    self.setf(dst + 1, x[2] * y[0] - x[0] * y[2]);
                    self.setf(dst + 2, x[0] * y[1] - x[1] * y[0]);
                },
                .mat_vec, .vec_mat, .mat_mat => {
                    // a is always the matrix; b the vector or right matrix.
                    var tmp: [9]f32 = undefined;
                    const n = w;
                    switch (ins.op) {
                        .mat_vec => for (0..n) |r| {
                            var sum: f32 = 0;
                            for (0..n) |col| sum += self.f(a + col * n + r) * self.f(b + col);
                            tmp[r] = sum;
                        },
                        .vec_mat => for (0..n) |col| {
                            var sum: f32 = 0;
                            for (0..n) |r| sum += self.f(b + r) * self.f(a + col * n + r);
                            tmp[col] = sum;
                        },
                        else => for (0..n) |col| for (0..n) |r| {
                            var sum: f32 = 0;
                            for (0..n) |k| sum += self.f(a + k * n + r) * self.f(b + col * n + k);
                            tmp[col * n + r] = sum;
                        },
                    }
                    const len: usize = if (ins.op == .mat_mat) n * n else n;
                    for (0..len) |k| self.setf(dst + k, tmp[k]);
                },
                .iadd, .isub, .imul, .idiv, .imod, .imin, .imax => {
                    const x = self.int(a);
                    const y = self.int(b);
                    self.setInt(dst, switch (ins.op) {
                        .iadd => std.math.add(i32, x, y) catch return error.ShaderFault,
                        .isub => std.math.sub(i32, x, y) catch return error.ShaderFault,
                        .imul => std.math.mul(i32, x, y) catch return error.ShaderFault,
                        .idiv => std.math.divTrunc(i32, x, y) catch return error.ShaderFault,
                        .imod => if (y == 0 or (x == std.math.minInt(i32) and y == -1)) return error.ShaderFault else @rem(x, y),
                        .imin => @min(x, y),
                        else => @max(x, y),
                    });
                },
                .ineg => self.setInt(dst, std.math.negate(self.int(a)) catch return error.ShaderFault),
                .iabs => {
                    const x = self.int(a);
                    if (x == std.math.minInt(i32)) return error.ShaderFault;
                    self.setInt(dst, if (x < 0) -x else x);
                },
                .flt => self.registers[dst] = @intFromBool(self.f(a) < self.f(b)),
                .fle => self.registers[dst] = @intFromBool(self.f(a) <= self.f(b)),
                .feq, .fne => {
                    var equal = true;
                    for (0..@max(w, 1)) |k| {
                        if (self.f(a + k) != self.f(b + k)) equal = false;
                    }
                    self.registers[dst] = @intFromBool(equal == (ins.op == .feq));
                },
                .ilt => self.registers[dst] = @intFromBool(self.int(a) < self.int(b)),
                .ile => self.registers[dst] = @intFromBool(self.int(a) <= self.int(b)),
                .ieq => self.registers[dst] = @intFromBool(self.registers[a] == self.registers[b]),
                .ine => self.registers[dst] = @intFromBool(self.registers[a] != self.registers[b]),
                .bnot => self.registers[dst] = @intFromBool(self.registers[a] == 0),
                .band => self.registers[dst] = @intFromBool(self.registers[a] != 0 and self.registers[b] != 0),
                .bor => self.registers[dst] = @intFromBool(self.registers[a] != 0 or self.registers[b] != 0),
                .itof => self.setf(dst, @floatFromInt(self.int(a))),
                .ftoi => {
                    const x = self.f(a);
                    if (!std.math.isFinite(x) or x >= 2147483648.0 or x < -2147483648.0) return error.ShaderFault;
                    self.setInt(dst, @intFromFloat(x));
                },
                .sample => {
                    const sampler = self.sampler orelse return error.ShaderFault;
                    const value = sampler.sample(self.f(a), self.f(a + 1));
                    for (0..4) |k| self.setf(dst + k, value[k]);
                },
            }
        }
    }
};
