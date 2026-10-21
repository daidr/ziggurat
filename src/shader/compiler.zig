//! Single-pass compiler from shader source to register code. Each statement
//! is type checked as it is parsed, and every program's worst-case step count
//! is summed while code is emitted: loops have literal bounds, functions are
//! called only after their definition (so there is no recursion) and every
//! function's register frame is static.
const std = @import("std");

/// Value types. Matrices are column-major; `bool` and `int` occupy one
/// 32-bit word like `float`.
pub const Type = enum(u8) {
    void,
    bool,
    int,
    float,
    vec2,
    vec3,
    vec4,
    mat2,
    mat3,

    pub fn words(self: Type) u16 {
        return switch (self) {
            .void => 0,
            .bool, .int, .float => 1,
            .vec2 => 2,
            .vec3 => 3,
            .vec4, .mat2 => 4,
            .mat3 => 9,
        };
    }
    pub fn isFloat(self: Type) bool {
        return switch (self) {
            .float, .vec2, .vec3, .vec4, .mat2, .mat3 => true,
            else => false,
        };
    }
    pub fn isVector(self: Type) bool {
        return self == .vec2 or self == .vec3 or self == .vec4;
    }
    pub fn isMatrix(self: Type) bool {
        return self == .mat2 or self == .mat3;
    }
    /// float, vec2, vec3 and vec4: the types most built-in functions accept.
    pub fn isGeneric(self: Type) bool {
        return self == .float or self.isVector();
    }
    pub fn vector(n: u16) Type {
        return switch (n) {
            1 => .float,
            2 => .vec2,
            3 => .vec3,
            else => .vec4,
        };
    }
    /// Rows (and columns) of a matrix.
    pub fn order(self: Type) u16 {
        return if (self == .mat2) 2 else 3;
    }
    pub fn name(self: Type) []const u8 {
        return @tagName(self);
    }
};

/// What an effect program computes, chosen by which entry function it defines:
/// `vec4 color(vec2 position, vec4 pixel)` maps each pixel's color,
/// `vec2 distort(vec2 position)` picks where each pixel reads its content from,
/// and `vec4 layer(vec2 position)` computes each pixel from `sample` reads.
pub const Kind = enum(u8) { color, distortion, layer };

pub const Op = enum(u8) {
    halt,
    fault,
    mov,
    zero,
    splat,
    swizzle,
    store_swizzle,
    load_index,
    store_index,
    jump,
    jump_zero,
    call,
    ret,
    select,
    fadd,
    fsub,
    fmul,
    fdiv,
    fmod,
    fmin,
    fmax,
    fpow,
    fatan2,
    fstep,
    fneg,
    fclamp,
    fmix,
    fsmoothstep,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sqrt,
    inversesqrt,
    exp,
    log,
    exp2,
    log2,
    fabs,
    sign,
    floor,
    ceil,
    fract,
    round,
    dot,
    length,
    distance,
    normalize,
    cross,
    mat_vec,
    vec_mat,
    mat_mat,
    iadd,
    isub,
    imul,
    idiv,
    imod,
    ineg,
    iabs,
    imin,
    imax,
    flt,
    fle,
    feq,
    fne,
    ilt,
    ile,
    ieq,
    ine,
    bnot,
    band,
    bor,
    itof,
    ftoi,
    sample,
};
/// a/b/c read one word and broadcast it across `w` components.
pub const broadcast_a: u8 = 1;
pub const broadcast_b: u8 = 2;
pub const broadcast_c: u8 = 4;

/// One register instruction. Registers are 32-bit word offsets.
pub const Instruction = extern struct {
    op: Op,
    w: u8 = 1,
    flags: u8 = 0,
    reserved: u8 = 0,
    dst: u16 = 0,
    a: u16 = 0,
    b: u16 = 0,
    c: u16 = 0,
};
comptime {
    if (@sizeOf(Instruction) != 12) @compileError("shader instruction ABI mismatch");
}

pub const max_source_bytes = 64 * 1024;
pub const max_instructions = 16 * 1024;
pub const max_register_words = 4096;
pub const max_uniform_words = 64;
pub const max_constant_words = 512;
pub const max_uniforms = 32;
pub const max_functions = 32;
pub const max_params = 8;
pub const max_array = 64;
pub const max_depth = 32;
/// Register layout: builtins, then uniforms, constants and frames.
pub const size_register: u16 = 0;
pub const scale_register: u16 = 2;
pub const uniform_base: u16 = 3;
pub const constant_base: u16 = uniform_base + max_uniform_words;
pub const frame_base: u16 = constant_base + max_constant_words;
/// Return slot value that ends a run instead of jumping back.
pub const return_halt: u32 = std.math.maxInt(u32);

pub const Options = struct {
    /// Worst-case instructions one pixel may execute; larger programs fail
    /// to compile.
    max_steps: u32 = 4096,
    /// Largest literal trip count a single loop may have.
    max_loop: u32 = 1024,
};

/// Where and why compilation failed. Lines and columns count from 1, in bytes.
pub const Diagnostic = struct {
    line: u32 = 0,
    column: u32 = 0,
    buffer: [160]u8 = undefined,
    len: usize = 0,
    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// A typed uniform slot. Handles carry their program's identity, so a value
/// buffer rejects a handle from another program.
pub const Uniform = struct {
    program: u64,
    ty: Type,
    /// Array length; 0 for a single value.
    count: u16,
    /// Word offset inside the value buffer.
    offset: u16,
    pub fn words(self: Uniform) u16 {
        return self.ty.words() * @max(self.count, 1);
    }
};

const UniformEntry = struct { name_start: u32, name_len: u32, uniform: Uniform };

var next_identity = std.atomic.Value(u64).init(1);

/// Compiled, immutable program. It owns its code, constants and uniform names.
pub const Program = struct {
    allocator: std.mem.Allocator,
    identity: u64,
    kind: Kind,
    code: []Instruction,
    /// Initial register contents up to `image.len`; constants live here.
    image: []u32,
    /// Instructions run once per application before the first pixel.
    prologue_end: u16,
    entry: u16,
    entry_slot: u16,
    position_register: u16,
    pixel_register: u16,
    result_register: u16,
    register_words: u16,
    uniform_words: u16,
    uniforms: []UniformEntry,
    names: []u8,
    /// Worst-case instructions for one pixel, excluding the prologue.
    max_steps: u32,
    prologue_steps: u32,

    pub fn destroy(self: *Program) void {
        const allocator = self.allocator;
        allocator.free(self.code);
        allocator.free(self.image);
        allocator.free(self.uniforms);
        allocator.free(self.names);
        allocator.destroy(self);
    }
    pub fn uniform(self: *const Program, name: []const u8) ?Uniform {
        for (self.uniforms) |entry| if (std.mem.eql(u8, self.names[entry.name_start..][0..entry.name_len], name)) return entry.uniform;
        return null;
    }
    pub fn uniformCount(self: *const Program) usize {
        return self.uniforms.len;
    }
    pub fn uniformName(self: *const Program, index: usize) []const u8 {
        const entry = self.uniforms[index];
        return self.names[entry.name_start..][0..entry.name_len];
    }
};

const Tag = enum {
    eof,
    ident,
    int_lit,
    float_lit,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    semicolon,
    dot,
    question,
    colon,
    plus,
    minus,
    star,
    slash,
    percent,
    bang,
    lt,
    le,
    gt,
    ge,
    eq_eq,
    bang_eq,
    amp_amp,
    pipe_pipe,
    assign,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    plus_plus,
    minus_minus,
};
const Token = struct { tag: Tag, start: u32, end: u32, line: u32, column: u32 };

const Symbol = struct {
    name: []const u8,
    ty: Type,
    count: u16 = 0,
    reg: u16,
    mutable: bool,
};
const Function = struct {
    name: []const u8,
    ret: Type,
    params: [max_params]Type = undefined,
    param_regs: [max_params]u16 = undefined,
    param_count: usize = 0,
    result: u16 = 0,
    slot: u16 = 0,
    pc: u16 = 0,
    cost: u64 = 0,
};
const Place = union(enum) {
    none,
    whole: struct { reg: u16, ty: Type, mutable: bool },
    element: struct { base: u16, index: u16, count: u16, elem: Type, mutable: bool },
    swizzle: struct { base: u16, mask: [4]u8, len: u8, unique: bool, mutable: bool },
};
const Value = struct {
    ty: Type,
    reg: u16,
    /// Array length when the value names a whole array; arrays only index.
    count: u16 = 0,
    int_literal: ?i64 = null,
    place: Place = .none,
};
const Loop = struct { breaks: [32]u16 = undefined, break_len: usize = 0, continues: [32]u16 = undefined, continue_len: usize = 0 };

const Compiler = struct {
    gpa: std.mem.Allocator,
    source: []const u8,
    tokens: []Token,
    pos: usize = 0,
    diagnostic: *Diagnostic,
    options: Options,
    main: std.ArrayList(Instruction) = .empty,
    prologue: std.ArrayList(Instruction) = .empty,
    in_prologue: bool = false,
    image: [max_register_words]u32 = @splat(0),
    constant_words: u16 = 0,
    uniform_words: u16 = 0,
    next_register: u16 = frame_base,
    peak_register: u16 = frame_base,
    symbols: std.ArrayList(Symbol) = .empty,
    functions: std.ArrayList(Function) = .empty,
    uniforms: std.ArrayList(UniformEntry) = .empty,
    names: std.ArrayList(u8) = .empty,
    cost: u64 = 0,
    prologue_cost: u64 = 0,
    loops: [max_depth]Loop = undefined,
    loop_depth: usize = 0,
    depth: usize = 0,
    function: ?*Function = null,
    entry: ?usize = null,
    kind: Kind = .color,
    uses_sample: ?usize = null,
    identity: u64,

    fn deinit(self: *Compiler) void {
        self.main.deinit(self.gpa);
        self.prologue.deinit(self.gpa);
        self.symbols.deinit(self.gpa);
        self.functions.deinit(self.gpa);
        self.uniforms.deinit(self.gpa);
        self.names.deinit(self.gpa);
    }

    fn fail(self: *Compiler, at: usize, comptime format: []const u8, args: anytype) error{InvalidShader} {
        const token = self.tokens[@min(at, self.tokens.len - 1)];
        self.diagnostic.line = token.line;
        self.diagnostic.column = token.column;
        const written = std.fmt.bufPrint(&self.diagnostic.buffer, format, args) catch blk: {
            const tail = "...";
            @memcpy(self.diagnostic.buffer[self.diagnostic.buffer.len - tail.len ..], tail);
            break :blk self.diagnostic.buffer[0..];
        };
        self.diagnostic.len = written.len;
        return error.InvalidShader;
    }
    fn text(self: *const Compiler, index: usize) []const u8 {
        const token = self.tokens[index];
        return self.source[token.start..token.end];
    }
    fn peek(self: *const Compiler, offset: usize) Tag {
        return self.tokens[@min(self.pos + offset, self.tokens.len - 1)].tag;
    }
    fn advance(self: *Compiler) usize {
        const index = self.pos;
        if (self.tokens[index].tag != .eof) self.pos += 1;
        return index;
    }
    fn expect(self: *Compiler, tag: Tag, what: []const u8) !usize {
        if (self.peek(0) != tag) return self.fail(self.pos, "expected {s}", .{what});
        return self.advance();
    }
    fn eat(self: *Compiler, tag: Tag) bool {
        if (self.peek(0) != tag) return false;
        _ = self.advance();
        return true;
    }
    fn isWord(self: *const Compiler, offset: usize, word: []const u8) bool {
        const index = @min(self.pos + offset, self.tokens.len - 1);
        return self.tokens[index].tag == .ident and std.mem.eql(u8, self.text(index), word);
    }
    fn typeAt(self: *const Compiler, offset: usize) ?Type {
        const index = @min(self.pos + offset, self.tokens.len - 1);
        if (self.tokens[index].tag != .ident) return null;
        return typeNamed(self.text(index));
    }

    fn emit(self: *Compiler, instruction: Instruction) !void {
        const list = if (self.in_prologue) &self.prologue else &self.main;
        if (self.main.items.len + self.prologue.items.len >= max_instructions) return self.fail(self.pos, "program has more than {d} instructions", .{max_instructions});
        try list.append(self.gpa, instruction);
        if (self.in_prologue) self.prologue_cost += 1 else self.cost +|= 1;
    }
    fn here(self: *const Compiler) u16 {
        return @intCast(self.main.items.len);
    }
    fn temp(self: *Compiler, words: u16) !u16 {
        const reg = self.next_register;
        if (@as(u32, reg) + words > max_register_words) return self.fail(self.pos, "program needs more than {d} register words", .{max_register_words});
        self.next_register += words;
        self.peak_register = @max(self.peak_register, self.next_register);
        return reg;
    }
    fn constant(self: *Compiler, words: []const u32) !u16 {
        // Reuse an identical run of constant words.
        var start: u16 = 0;
        while (start + words.len <= self.constant_words) : (start += 1) {
            if (std.mem.eql(u32, self.image[constant_base + start ..][0..words.len], words)) return constant_base + start;
        }
        if (self.constant_words + words.len > max_constant_words) return self.fail(self.pos, "program has more than {d} constant words", .{max_constant_words});
        const reg = constant_base + self.constant_words;
        @memcpy(self.image[reg..][0..words.len], words);
        self.constant_words += @intCast(words.len);
        return reg;
    }
    fn floatConstant(self: *Compiler, value: f32) !u16 {
        return self.constant(&.{@bitCast(value)});
    }
    fn intConstant(self: *Compiler, value: i32) !u16 {
        return self.constant(&.{@bitCast(value)});
    }

    fn lookup(self: *const Compiler, name: []const u8) ?Symbol {
        var index = self.symbols.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.symbols.items[index].name, name)) return self.symbols.items[index];
        }
        return null;
    }
    fn findFunction(self: *const Compiler, name: []const u8) ?usize {
        for (self.functions.items, 0..) |function, index| if (std.mem.eql(u8, function.name, name)) return index;
        return null;
    }
    fn declare(self: *Compiler, at: usize, symbol: Symbol) !void {
        const name = symbol.name;
        if (typeNamed(name) != null or isKeyword(name) or builtinNamed(name) != null) return self.fail(at, "'{s}' is a reserved name", .{name});
        if (self.lookup(name) != null) return self.fail(at, "'{s}' is already declared", .{name});
        if (self.findFunction(name) != null) return self.fail(at, "'{s}' is already a function", .{name});
        try self.symbols.append(self.gpa, symbol);
    }

    // Top level --------------------------------------------------------

    fn program(self: *Compiler) !void {
        try self.symbols.append(self.gpa, .{ .name = "size", .ty = .vec2, .reg = size_register, .mutable = false });
        try self.symbols.append(self.gpa, .{ .name = "scale", .ty = .float, .reg = scale_register, .mutable = false });
        while (self.peek(0) != .eof) {
            if (self.isWord(0, "uniform")) {
                try self.uniformDeclaration();
            } else if (self.isWord(0, "const")) {
                try self.globalConstant();
            } else if (self.typeAt(0) != null and self.peek(1) == .ident and self.peek(2) == .l_paren) {
                try self.functionDefinition();
            } else {
                return self.fail(self.pos, "expected a uniform, constant or function", .{});
            }
        }
        if (self.entry == null) return self.fail(self.pos, "program defines none of color, distort or layer", .{});
        if (self.uses_sample) |at| if (self.kind != .layer) return self.fail(at, "sample is only available in a layer program", .{});
    }
    fn uniformDeclaration(self: *Compiler) !void {
        _ = self.advance();
        const type_at = self.pos;
        const ty = self.typeAt(0) orelse return self.fail(self.pos, "expected a uniform type", .{});
        if (ty == .void) return self.fail(type_at, "a uniform cannot be void", .{});
        _ = self.advance();
        const name_at = try self.expect(.ident, "a uniform name");
        const count = try self.arraySuffix();
        _ = try self.expect(.semicolon, "';'");
        const words = ty.words() * @max(count, 1);
        if (self.uniform_words + words > max_uniform_words) return self.fail(name_at, "uniforms use more than {d} words", .{max_uniform_words});
        if (self.uniforms.items.len == max_uniforms) return self.fail(name_at, "program has more than {d} uniforms", .{max_uniforms});
        const reg = uniform_base + self.uniform_words;
        const name = self.text(name_at);
        try self.declare(name_at, .{ .name = name, .ty = ty, .count = count, .reg = reg, .mutable = false });
        const start: u32 = @intCast(self.names.items.len);
        try self.names.appendSlice(self.gpa, name);
        try self.uniforms.append(self.gpa, .{ .name_start = start, .name_len = @intCast(name.len), .uniform = .{ .program = self.identity, .ty = ty, .count = count, .offset = self.uniform_words } });
        self.uniform_words += words;
    }
    fn arraySuffix(self: *Compiler) !u16 {
        if (!self.eat(.l_bracket)) return 0;
        const at = try self.expect(.int_lit, "an array length");
        const length = std.fmt.parseInt(u32, self.text(at), 10) catch return self.fail(at, "invalid array length", .{});
        if (length == 0 or length > max_array) return self.fail(at, "array length must be 1 to {d}", .{max_array});
        _ = try self.expect(.r_bracket, "']'");
        return @intCast(length);
    }
    fn globalConstant(self: *Compiler) !void {
        _ = self.advance();
        self.in_prologue = true;
        defer self.in_prologue = false;
        try self.declaration(false);
    }
    fn functionDefinition(self: *Compiler) !void {
        const ret = self.typeAt(0).?;
        _ = self.advance();
        const name_at = self.advance();
        const name = self.text(name_at);
        if (self.functions.items.len == max_functions) return self.fail(name_at, "program has more than {d} functions", .{max_functions});
        if (self.findFunction(name) != null or self.lookup(name) != null) return self.fail(name_at, "'{s}' is already declared", .{name});
        if (typeNamed(name) != null or isKeyword(name) or builtinNamed(name) != null) return self.fail(name_at, "'{s}' is a reserved name", .{name});
        var function: Function = .{ .name = name, .ret = ret };
        const scope = self.symbols.items.len;
        _ = try self.expect(.l_paren, "'('");
        if (!self.eat(.r_paren)) {
            while (true) {
                const param_at = self.pos;
                const ty = self.typeAt(0) orelse return self.fail(self.pos, "expected a parameter type", .{});
                if (ty == .void) return self.fail(param_at, "a parameter cannot be void", .{});
                _ = self.advance();
                const param_name = try self.expect(.ident, "a parameter name");
                if (function.param_count == max_params) return self.fail(param_name, "a function takes at most {d} parameters", .{max_params});
                const reg = try self.temp(ty.words());
                try self.declare(param_name, .{ .name = self.text(param_name), .ty = ty, .reg = reg, .mutable = true });
                function.params[function.param_count] = ty;
                function.param_regs[function.param_count] = reg;
                function.param_count += 1;
                if (self.eat(.r_paren)) break;
                _ = try self.expect(.comma, "',' or ')'");
            }
        }
        function.result = try self.temp(ret.words());
        function.slot = try self.temp(1);
        function.pc = self.here();
        const entry_kind: ?Kind = if (std.mem.eql(u8, name, "color")) .color else if (std.mem.eql(u8, name, "distort")) .distortion else if (std.mem.eql(u8, name, "layer")) .layer else null;
        if (entry_kind) |kind| {
            if (self.entry != null) return self.fail(name_at, "a program has exactly one entry function", .{});
            const ok = switch (kind) {
                .color => ret == .vec4 and function.param_count == 2 and function.params[0] == .vec2 and function.params[1] == .vec4,
                .distortion => ret == .vec2 and function.param_count == 1 and function.params[0] == .vec2,
                .layer => ret == .vec4 and function.param_count == 1 and function.params[0] == .vec2,
            };
            if (!ok) return self.fail(name_at, "{s}", .{switch (kind) {
                .color => "the color entry is vec4 color(vec2 position, vec4 pixel)",
                .distortion => "the distort entry is vec2 distort(vec2 position)",
                .layer => "the layer entry is vec4 layer(vec2 position)",
            }});
            self.kind = kind;
        }
        const saved_cost = self.cost;
        self.cost = 0;
        var current = function;
        self.function = &current;
        const returns = try self.block();
        self.function = null;
        if (!returns) {
            if (ret != .void) return self.fail(self.pos - 1, "function '{s}' can end without returning a value", .{name});
            try self.emit(.{ .op = .ret, .a = current.slot });
        }
        current.cost = self.cost;
        self.cost = saved_cost;
        if (current.cost > self.options.max_steps) return self.fail(name_at, "function '{s}' may run {d} steps; the limit is {d}", .{ name, current.cost, self.options.max_steps });
        self.symbols.shrinkRetainingCapacity(scope);
        // The whole frame, temporaries included, stays reserved: a later
        // function may call this one while its own frame is live.
        self.next_register = self.peak_register;
        try self.functions.append(self.gpa, current);
        if (entry_kind != null) self.entry = self.functions.items.len - 1;
    }

    // Statements -------------------------------------------------------

    /// Parses `{ ... }`; true when every path through it returns.
    fn block(self: *Compiler) anyerror!bool {
        _ = try self.expect(.l_brace, "'{'");
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return self.fail(self.pos, "blocks nest deeper than {d}", .{max_depth});
        const scope = self.symbols.items.len;
        const registers = self.next_register;
        var returns = false;
        while (!self.eat(.r_brace)) {
            if (self.peek(0) == .eof) return self.fail(self.pos, "expected '}}'", .{});
            if (try self.statement()) returns = true;
        }
        self.symbols.shrinkRetainingCapacity(scope);
        self.next_register = registers;
        return returns;
    }
    fn statement(self: *Compiler) anyerror!bool {
        const start = self.pos;
        const result = try self.statementInner();
        if (self.cost > self.options.max_steps) return self.fail(start, "program may run more than {d} steps here", .{self.options.max_steps});
        return result;
    }
    fn statementInner(self: *Compiler) anyerror!bool {
        if (self.peek(0) == .l_brace) return self.block();
        if (self.isWord(0, "if")) return self.ifStatement();
        if (self.isWord(0, "for")) {
            try self.forStatement();
            return false;
        }
        if (self.isWord(0, "return")) {
            try self.returnStatement();
            return true;
        }
        if (self.isWord(0, "break") or self.isWord(0, "continue")) {
            const at = self.advance();
            const is_break = std.mem.eql(u8, self.text(at), "break");
            if (self.loop_depth == 0) return self.fail(at, "{s} outside a loop", .{self.text(at)});
            _ = try self.expect(.semicolon, "';'");
            const loop = &self.loops[self.loop_depth - 1];
            if ((if (is_break) loop.break_len else loop.continue_len) == 32) return self.fail(at, "a loop has more than 32 {s} statements", .{self.text(at)});
            if (is_break) {
                loop.breaks[loop.break_len] = self.here();
                loop.break_len += 1;
            } else {
                loop.continues[loop.continue_len] = self.here();
                loop.continue_len += 1;
            }
            try self.emit(.{ .op = .jump });
            return false;
        }
        if (self.isWord(0, "const")) {
            _ = self.advance();
            try self.declaration(false);
            return false;
        }
        if (self.typeAt(0) != null and self.peek(1) == .ident) {
            try self.declaration(true);
            return false;
        }
        try self.expressionStatement();
        return false;
    }
    fn declaration(self: *Compiler, mutable: bool) !void {
        const type_at = self.pos;
        const ty = self.typeAt(0) orelse return self.fail(self.pos, "expected a type", .{});
        if (ty == .void) return self.fail(type_at, "a variable cannot be void", .{});
        _ = self.advance();
        const name_at = try self.expect(.ident, "a variable name");
        const count = try self.arraySuffix();
        const words = ty.words() * @max(count, 1);
        const reg = try self.temp(words);
        if (count != 0) {
            if (!mutable) return self.fail(name_at, "a constant cannot be an array", .{});
            if (self.peek(0) == .assign) return self.fail(self.pos, "arrays start zeroed and take no initializer", .{});
            try self.emit(.{ .op = .zero, .dst = reg, .c = words });
        } else if (self.eat(.assign)) {
            const marker = self.next_register;
            const value = try self.coerce(try self.expression(), ty, self.pos - 1);
            try self.emit(.{ .op = .mov, .w = @intCast(words), .dst = reg, .a = value.reg });
            self.next_register = marker;
        } else {
            if (!mutable) return self.fail(name_at, "a constant needs a value", .{});
            try self.emit(.{ .op = .zero, .dst = reg, .c = words });
        }
        _ = try self.expect(.semicolon, "';'");
        try self.declare(name_at, .{ .name = self.text(name_at), .ty = ty, .count = count, .reg = reg, .mutable = mutable });
    }
    fn ifStatement(self: *Compiler) !bool {
        _ = self.advance();
        _ = try self.expect(.l_paren, "'('");
        const marker = self.next_register;
        const cond_at = self.pos;
        const condition = try self.expression();
        if (condition.ty != .bool or condition.count != 0) return self.fail(cond_at, "an if condition must be bool", .{});
        _ = try self.expect(.r_paren, "')'");
        const branch = self.here();
        try self.emit(.{ .op = .jump_zero, .a = condition.reg });
        self.next_register = marker;
        const before = self.cost;
        const then_returns = try self.branchStatement();
        const then_cost = self.cost - before;
        if (self.isWord(0, "else")) {
            _ = self.advance();
            const skip = self.here();
            try self.emit(.{ .op = .jump });
            self.main.items[branch].dst = self.here();
            const after_then = self.cost;
            const else_returns = try self.branchStatement();
            const else_cost = self.cost - after_then;
            self.main.items[skip].dst = self.here();
            self.cost = before + @max(then_cost + 1, else_cost);
            return then_returns and else_returns;
        }
        self.main.items[branch].dst = self.here();
        return false;
    }
    /// A statement in its own scope, so a declaration does not leak out.
    fn branchStatement(self: *Compiler) !bool {
        const scope = self.symbols.items.len;
        const registers = self.next_register;
        defer {
            self.symbols.shrinkRetainingCapacity(scope);
            self.next_register = registers;
        }
        return self.statement();
    }
    fn literalInt(self: *Compiler) !i64 {
        const negative = self.eat(.minus);
        const at = try self.expect(.int_lit, "an integer literal");
        const value = std.fmt.parseInt(i64, self.text(at), 10) catch return self.fail(at, "integer literal out of range", .{});
        const result = if (negative) -value else value;
        if (result < std.math.minInt(i32) or result > std.math.maxInt(i32)) return self.fail(at, "integer literal out of range", .{});
        return result;
    }
    fn forStatement(self: *Compiler) !void {
        const for_at = self.advance();
        if (self.loop_depth == max_depth) return self.fail(for_at, "loops nest deeper than {d}", .{max_depth});
        _ = try self.expect(.l_paren, "'('");
        if (!self.isWord(0, "int")) return self.fail(self.pos, "a loop counter is 'int name = literal'", .{});
        _ = self.advance();
        const name_at = try self.expect(.ident, "a loop counter name");
        const name = self.text(name_at);
        _ = try self.expect(.assign, "'='");
        const first = try self.literalInt();
        _ = try self.expect(.semicolon, "';'");
        const cond_name = try self.expect(.ident, "the loop counter");
        if (!std.mem.eql(u8, self.text(cond_name), name)) return self.fail(cond_name, "a loop condition tests its own counter", .{});
        const compare = self.advance();
        const relation = self.tokens[compare].tag;
        switch (relation) {
            .lt, .le, .gt, .ge, .bang_eq => {},
            else => return self.fail(compare, "expected <, <=, >, >= or !=", .{}),
        }
        const bound = try self.literalInt();
        _ = try self.expect(.semicolon, "';'");
        const step_name = try self.expect(.ident, "the loop counter");
        if (!std.mem.eql(u8, self.text(step_name), name)) return self.fail(step_name, "a loop step changes its own counter", .{});
        const step: i64 = switch (self.peek(0)) {
            .plus_plus => blk: {
                _ = self.advance();
                break :blk 1;
            },
            .minus_minus => blk: {
                _ = self.advance();
                break :blk -1;
            },
            .plus_eq => blk: {
                _ = self.advance();
                break :blk try self.literalInt();
            },
            .minus_eq => blk: {
                _ = self.advance();
                break :blk -(try self.literalInt());
            },
            else => return self.fail(self.pos, "expected ++, --, += or -=", .{}),
        };
        _ = try self.expect(.r_paren, "')'");
        const trips = tripCount(first, relation, bound, step) orelse return self.fail(step_name, "this loop never ends", .{});
        if (trips > self.options.max_loop) return self.fail(for_at, "loop runs {d} times; the limit is {d}", .{ trips, self.options.max_loop });
        // The counter is read-only inside the body.
        const scope = self.symbols.items.len;
        const registers = self.next_register;
        const counter = try self.temp(1);
        try self.declare(name_at, .{ .name = name, .ty = .int, .reg = counter, .mutable = false });
        const before = self.cost;
        try self.emit(.{ .op = .mov, .dst = counter, .a = try self.intConstant(@intCast(first)) });
        const flag = try self.temp(1);
        const bound_reg = try self.intConstant(@intCast(bound));
        const top = self.here();
        switch (relation) {
            .lt => try self.emit(.{ .op = .ilt, .dst = flag, .a = counter, .b = bound_reg }),
            .le => try self.emit(.{ .op = .ile, .dst = flag, .a = counter, .b = bound_reg }),
            .gt => try self.emit(.{ .op = .ilt, .dst = flag, .a = bound_reg, .b = counter }),
            .ge => try self.emit(.{ .op = .ile, .dst = flag, .a = bound_reg, .b = counter }),
            else => try self.emit(.{ .op = .ine, .dst = flag, .a = counter, .b = bound_reg }),
        }
        const exit = self.here();
        try self.emit(.{ .op = .jump_zero, .a = flag });
        self.loops[self.loop_depth] = .{};
        self.loop_depth += 1;
        const body_start = self.cost;
        _ = try self.branchStatement();
        const loop = self.loops[self.loop_depth - 1];
        self.loop_depth -= 1;
        const continue_pc = self.here();
        try self.emit(.{ .op = .iadd, .dst = counter, .a = counter, .b = try self.intConstant(@intCast(step)) });
        try self.emit(.{ .op = .jump, .dst = top });
        const body = self.cost - body_start;
        const end = self.here();
        self.main.items[exit].dst = end;
        for (loop.breaks[0..loop.break_len]) |pc| self.main.items[pc].dst = end;
        for (loop.continues[0..loop.continue_len]) |pc| self.main.items[pc].dst = continue_pc;
        // Setup, then every trip runs the test and body, then a final test.
        self.cost = before +| 1 +| (@as(u64, trips) *| (body +| 2)) +| 2;
        self.symbols.shrinkRetainingCapacity(scope);
        self.next_register = registers;
    }
    fn returnStatement(self: *Compiler) !void {
        const at = self.advance();
        const function = self.function orelse return self.fail(at, "return outside a function", .{});
        if (function.ret == .void) {
            if (self.peek(0) != .semicolon) return self.fail(self.pos, "function '{s}' returns no value", .{function.name});
        } else {
            const marker = self.next_register;
            const value = try self.coerce(try self.expression(), function.ret, at + 1);
            try self.emit(.{ .op = .mov, .w = @intCast(function.ret.words()), .dst = function.result, .a = value.reg });
            self.next_register = marker;
        }
        _ = try self.expect(.semicolon, "';'");
        try self.emit(.{ .op = .ret, .a = function.slot });
    }
    fn expressionStatement(self: *Compiler) !void {
        const marker = self.next_register;
        defer self.next_register = marker;
        const at = self.pos;
        const target = try self.expression();
        const operator = self.peek(0);
        switch (operator) {
            .assign, .plus_eq, .minus_eq, .star_eq, .slash_eq => {
                const op_at = self.advance();
                var value = try self.expression();
                if (operator != .assign) {
                    const binary: Tag = switch (operator) {
                        .plus_eq => .plus,
                        .minus_eq => .minus,
                        .star_eq => .star,
                        else => .slash,
                    };
                    value = try self.arithmetic(binary, target, value, op_at);
                }
                try self.store(target, value, at);
            },
            .plus_plus, .minus_minus => {
                const op_at = self.advance();
                if (target.ty != .int and target.ty != .float) return self.fail(op_at, "++ and -- apply to int or float", .{});
                const one: Value = if (target.ty == .int) .{ .ty = .int, .reg = try self.intConstant(1), .int_literal = 1 } else .{ .ty = .float, .reg = try self.floatConstant(1) };
                try self.store(target, try self.arithmetic(if (operator == .plus_plus) .plus else .minus, target, one, op_at), at);
            },
            else => {},
        }
        _ = try self.expect(.semicolon, "';'");
    }
    fn store(self: *Compiler, target: Value, raw: Value, at: usize) !void {
        switch (target.place) {
            .none => return self.fail(at, "cannot assign to this expression", .{}),
            .whole => |place| {
                if (!place.mutable) return self.fail(at, "cannot assign to a constant, uniform or loop counter", .{});
                if (target.count != 0) return self.fail(at, "cannot assign a whole array", .{});
                const value = try self.coerce(raw, place.ty, at);
                try self.emit(.{ .op = .mov, .w = @intCast(place.ty.words()), .dst = place.reg, .a = value.reg });
            },
            .element => |place| {
                if (!place.mutable) return self.fail(at, "cannot assign to a constant, uniform or loop counter", .{});
                const value = try self.coerce(raw, place.elem, at);
                try self.emit(.{ .op = .store_index, .w = @intCast(place.elem.words()), .dst = place.base, .a = value.reg, .b = place.index, .c = place.count });
            },
            .swizzle => |place| {
                if (!place.mutable) return self.fail(at, "cannot assign to a constant, uniform or loop counter", .{});
                if (!place.unique) return self.fail(at, "a swizzle written to repeats a component", .{});
                const value = try self.coerce(raw, Type.vector(place.len), at);
                try self.emit(.{ .op = .store_swizzle, .w = place.len, .dst = place.base, .a = value.reg, .b = packMask(place.mask) });
            },
        }
    }

    // Expressions ------------------------------------------------------

    fn expression(self: *Compiler) anyerror!Value {
        return self.ternary();
    }
    fn ternary(self: *Compiler) anyerror!Value {
        const at = self.pos;
        const condition = try self.logicalOr();
        if (self.peek(0) != .question) return condition;
        const question = self.advance();
        if (condition.ty != .bool or condition.count != 0) return self.fail(at, "a ?: condition must be bool", .{});
        const yes = try self.ternary();
        _ = try self.expect(.colon, "':'");
        const no = try self.ternary();
        const pair = try self.unify(yes, no, question);
        if (pair[0].ty == .void) return self.fail(question, "?: needs values", .{});
        const dst = try self.temp(pair[0].ty.words());
        try self.emit(.{ .op = .select, .w = @intCast(pair[0].ty.words()), .dst = dst, .a = pair[0].reg, .b = pair[1].reg, .c = condition.reg });
        return .{ .ty = pair[0].ty, .reg = dst };
    }
    fn logicalOr(self: *Compiler) anyerror!Value {
        var left = try self.logicalAnd();
        while (self.peek(0) == .pipe_pipe) {
            const at = self.advance();
            const right = try self.logicalAnd();
            left = try self.logic(.bor, left, right, at);
        }
        return left;
    }
    fn logicalAnd(self: *Compiler) anyerror!Value {
        var left = try self.equality();
        while (self.peek(0) == .amp_amp) {
            const at = self.advance();
            const right = try self.equality();
            left = try self.logic(.band, left, right, at);
        }
        return left;
    }
    fn logic(self: *Compiler, op: Op, left: Value, right: Value, at: usize) !Value {
        if (left.ty != .bool or right.ty != .bool or left.count != 0 or right.count != 0) return self.fail(at, "&& and || take bool operands", .{});
        const dst = try self.temp(1);
        try self.emit(.{ .op = op, .dst = dst, .a = left.reg, .b = right.reg });
        return .{ .ty = .bool, .reg = dst };
    }
    fn equality(self: *Compiler) anyerror!Value {
        var left = try self.relational();
        while (self.peek(0) == .eq_eq or self.peek(0) == .bang_eq) {
            const at = self.advance();
            const equal = self.tokens[at].tag == .eq_eq;
            const right = try self.relational();
            const pair = try self.unify(left, right, at);
            const ty = pair[0].ty;
            const dst = try self.temp(1);
            if (ty.isFloat()) {
                try self.emit(.{ .op = if (equal) .feq else .fne, .w = @intCast(ty.words()), .dst = dst, .a = pair[0].reg, .b = pair[1].reg });
            } else {
                try self.emit(.{ .op = if (equal) .ieq else .ine, .dst = dst, .a = pair[0].reg, .b = pair[1].reg });
            }
            left = .{ .ty = .bool, .reg = dst };
        }
        return left;
    }
    fn relational(self: *Compiler) anyerror!Value {
        var left = try self.additive();
        while (true) {
            const tag = self.peek(0);
            if (tag != .lt and tag != .le and tag != .gt and tag != .ge) return left;
            const at = self.advance();
            const right = try self.additive();
            const pair = try self.unify(left, right, at);
            const ty = pair[0].ty;
            if (ty != .float and ty != .int) return self.fail(at, "comparisons take int or float scalars", .{});
            const swap = tag == .gt or tag == .ge;
            const a = if (swap) pair[1].reg else pair[0].reg;
            const b = if (swap) pair[0].reg else pair[1].reg;
            const strict = tag == .lt or tag == .gt;
            const op: Op = if (ty == .float) (if (strict) .flt else .fle) else (if (strict) .ilt else .ile);
            const dst = try self.temp(1);
            try self.emit(.{ .op = op, .dst = dst, .a = a, .b = b });
            left = .{ .ty = .bool, .reg = dst };
        }
    }
    fn additive(self: *Compiler) anyerror!Value {
        var left = try self.multiplicative();
        while (self.peek(0) == .plus or self.peek(0) == .minus) {
            const at = self.advance();
            const right = try self.multiplicative();
            left = try self.arithmetic(self.tokens[at].tag, left, right, at);
        }
        return left;
    }
    fn multiplicative(self: *Compiler) anyerror!Value {
        var left = try self.unary();
        while (self.peek(0) == .star or self.peek(0) == .slash or self.peek(0) == .percent) {
            const at = self.advance();
            const right = try self.unary();
            left = try self.arithmetic(self.tokens[at].tag, left, right, at);
        }
        return left;
    }
    fn arithmetic(self: *Compiler, tag: Tag, raw_left: Value, raw_right: Value, at: usize) !Value {
        if (raw_left.count != 0 or raw_right.count != 0) return self.fail(at, "arrays cannot be used in arithmetic", .{});
        var left = raw_left;
        var right = raw_right;
        // Integer literals adopt the float type beside them.
        if (left.ty.isFloat() and right.ty == .int) right = try self.coerce(right, .float, at);
        if (right.ty.isFloat() and left.ty == .int) left = try self.coerce(left, .float, at);
        if (left.ty == .int and right.ty == .int) {
            const op: Op = switch (tag) {
                .plus => .iadd,
                .minus => .isub,
                .star => .imul,
                .slash => .idiv,
                else => .imod,
            };
            const dst = try self.temp(1);
            try self.emit(.{ .op = op, .dst = dst, .a = left.reg, .b = right.reg });
            return .{ .ty = .int, .reg = dst };
        }
        if (!left.ty.isFloat() or !right.ty.isFloat()) return self.fail(at, "cannot apply '{s}' to {s} and {s}", .{ symbolOf(tag), left.ty.name(), right.ty.name() });
        if (tag == .star) {
            if (left.ty.isMatrix() and right.ty.isMatrix()) {
                if (left.ty != right.ty) return self.fail(at, "cannot multiply {s} by {s}", .{ left.ty.name(), right.ty.name() });
                const dst = try self.temp(left.ty.words());
                try self.emit(.{ .op = .mat_mat, .w = @intCast(left.ty.order()), .dst = dst, .a = left.reg, .b = right.reg });
                return .{ .ty = left.ty, .reg = dst };
            }
            if (left.ty.isMatrix() and right.ty.isVector()) {
                if (right.ty.words() != left.ty.order()) return self.fail(at, "cannot multiply {s} by {s}", .{ left.ty.name(), right.ty.name() });
                const dst = try self.temp(right.ty.words());
                try self.emit(.{ .op = .mat_vec, .w = @intCast(left.ty.order()), .dst = dst, .a = left.reg, .b = right.reg });
                return .{ .ty = right.ty, .reg = dst };
            }
            if (left.ty.isVector() and right.ty.isMatrix()) {
                if (left.ty.words() != right.ty.order()) return self.fail(at, "cannot multiply {s} by {s}", .{ left.ty.name(), right.ty.name() });
                const dst = try self.temp(left.ty.words());
                try self.emit(.{ .op = .vec_mat, .w = @intCast(right.ty.order()), .dst = dst, .a = right.reg, .b = left.reg });
                return .{ .ty = left.ty, .reg = dst };
            }
        }
        var flags: u8 = 0;
        var ty = left.ty;
        if (left.ty != right.ty) {
            if (left.ty == .float) {
                flags = broadcast_a;
                ty = right.ty;
            } else if (right.ty == .float) {
                flags = broadcast_b;
            } else return self.fail(at, "cannot apply '{s}' to {s} and {s}", .{ symbolOf(tag), left.ty.name(), right.ty.name() });
        }
        const op: Op = switch (tag) {
            .plus => .fadd,
            .minus => .fsub,
            .star => .fmul,
            .slash => .fdiv,
            else => .fmod,
        };
        const dst = try self.temp(ty.words());
        try self.emit(.{ .op = op, .w = @intCast(ty.words()), .flags = flags, .dst = dst, .a = left.reg, .b = right.reg });
        return .{ .ty = ty, .reg = dst };
    }
    fn unary(self: *Compiler) anyerror!Value {
        if (self.peek(0) == .minus) {
            const at = self.advance();
            // Fold negative literals so that `-2` stays an int literal.
            if (self.peek(0) == .int_lit) {
                const literal = try self.intLiteral(self.advance());
                const value = -literal;
                if (value < std.math.minInt(i32)) return self.fail(at, "integer literal out of range", .{});
                return self.postfix(.{ .ty = .int, .reg = try self.intConstant(@intCast(value)), .int_literal = value });
            }
            const operand = try self.unary();
            if (operand.count != 0) return self.fail(at, "arrays cannot be negated", .{});
            const dst = try self.temp(operand.ty.words());
            if (operand.ty == .int) {
                try self.emit(.{ .op = .ineg, .dst = dst, .a = operand.reg });
            } else if (operand.ty.isFloat()) {
                try self.emit(.{ .op = .fneg, .w = @intCast(operand.ty.words()), .dst = dst, .a = operand.reg });
            } else return self.fail(at, "cannot negate {s}", .{operand.ty.name()});
            return .{ .ty = operand.ty, .reg = dst };
        }
        if (self.peek(0) == .bang) {
            const at = self.advance();
            const operand = try self.unary();
            if (operand.ty != .bool or operand.count != 0) return self.fail(at, "! takes a bool", .{});
            const dst = try self.temp(1);
            try self.emit(.{ .op = .bnot, .dst = dst, .a = operand.reg });
            return .{ .ty = .bool, .reg = dst };
        }
        if (self.peek(0) == .plus) {
            _ = self.advance();
            return self.unary();
        }
        return self.postfix(try self.primary());
    }
    fn intLiteral(self: *Compiler, at: usize) !i64 {
        const value = std.fmt.parseInt(i64, self.text(at), 10) catch return self.fail(at, "integer literal out of range", .{});
        if (value > @as(i64, std.math.maxInt(i32)) + 1) return self.fail(at, "integer literal out of range", .{});
        return value;
    }
    fn primary(self: *Compiler) anyerror!Value {
        const at = self.pos;
        switch (self.peek(0)) {
            .int_lit => {
                _ = self.advance();
                const value = try self.intLiteral(at);
                if (value > std.math.maxInt(i32)) return self.fail(at, "integer literal out of range", .{});
                return .{ .ty = .int, .reg = try self.intConstant(@intCast(value)), .int_literal = value };
            },
            .float_lit => {
                _ = self.advance();
                const value = std.fmt.parseFloat(f32, self.text(at)) catch return self.fail(at, "invalid float literal", .{});
                if (!std.math.isFinite(value)) return self.fail(at, "float literal out of range", .{});
                return .{ .ty = .float, .reg = try self.floatConstant(value) };
            },
            .l_paren => {
                _ = self.advance();
                const value = try self.expression();
                _ = try self.expect(.r_paren, "')'");
                return .{ .ty = value.ty, .reg = value.reg, .count = value.count };
            },
            .ident => {},
            else => return self.fail(at, "expected an expression", .{}),
        }
        const name = self.text(at);
        _ = self.advance();
        if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) {
            return .{ .ty = .bool, .reg = try self.constant(&.{@intFromBool(name[0] == 't')}) };
        }
        if (self.peek(0) == .l_paren) {
            if (typeNamed(name)) |ty| return self.construct(ty, at);
            if (builtinNamed(name)) |builtin| return self.builtinCall(builtin, at);
            if (self.findFunction(name)) |index| return self.userCall(index, at);
            if (self.function) |current| if (std.mem.eql(u8, current.name, name)) return self.fail(at, "function '{s}' cannot call itself", .{name});
            return self.fail(at, "unknown function '{s}'", .{name});
        }
        const symbol = self.lookup(name) orelse return self.fail(at, "unknown name '{s}'", .{name});
        return .{ .ty = symbol.ty, .reg = symbol.reg, .count = symbol.count, .place = .{ .whole = .{ .reg = symbol.reg, .ty = symbol.ty, .mutable = symbol.mutable } } };
    }
    fn postfix(self: *Compiler, start: Value) anyerror!Value {
        var value = start;
        while (true) {
            if (self.peek(0) == .l_bracket) {
                const at = self.advance();
                const marker_place = value.place;
                const index = try self.expression();
                _ = try self.expect(.r_bracket, "']'");
                if (index.ty != .int or index.count != 0) return self.fail(at, "an index must be an int", .{});
                var elem: Type = undefined;
                var count: u16 = undefined;
                if (value.count != 0) {
                    elem = value.ty;
                    count = value.count;
                } else if (value.ty.isVector()) {
                    elem = .float;
                    count = value.ty.words();
                } else if (value.ty.isMatrix()) {
                    elem = Type.vector(value.ty.order());
                    count = value.ty.order();
                } else return self.fail(at, "cannot index {s}", .{value.ty.name()});
                if (index.int_literal) |literal| if (literal < 0 or literal >= count) return self.fail(at, "index {d} is out of range 0..{d}", .{ literal, count - 1 });
                const mutable = switch (marker_place) {
                    .whole => |place| place.mutable,
                    else => false,
                };
                const based = switch (marker_place) {
                    .whole => true,
                    else => false,
                };
                const base = value.reg;
                const dst = try self.temp(elem.words());
                try self.emit(.{ .op = .load_index, .w = @intCast(elem.words()), .dst = dst, .a = base, .b = index.reg, .c = count });
                const place: Place = if (based) .{ .element = .{ .base = base, .index = index.reg, .count = count, .elem = elem, .mutable = mutable } } else .none;
                value = .{ .ty = elem, .reg = dst, .place = place };
            } else if (self.peek(0) == .dot) {
                _ = self.advance();
                const at = try self.expect(.ident, "a swizzle");
                if (!value.ty.isVector() or value.count != 0) return self.fail(at, "only vectors have components", .{});
                const mask = parseSwizzle(self.text(at), value.ty.words()) orelse return self.fail(at, "invalid swizzle '{s}' for {s}", .{ self.text(at), value.ty.name() });
                const len: u8 = @intCast(self.text(at).len);
                const dst = try self.temp(len);
                try self.emit(.{ .op = .swizzle, .w = len, .dst = dst, .a = value.reg, .b = packMask(mask) });
                const place: Place = switch (value.place) {
                    .whole => |whole| .{ .swizzle = .{ .base = whole.reg, .mask = mask, .len = len, .unique = uniqueMask(mask, len), .mutable = whole.mutable } },
                    else => .none,
                };
                value = .{ .ty = Type.vector(len), .reg = dst, .place = place };
            } else return value;
        }
    }
    fn arguments(self: *Compiler, values: []Value, at: usize) !usize {
        _ = try self.expect(.l_paren, "'('");
        var len: usize = 0;
        if (self.eat(.r_paren)) return 0;
        while (true) {
            if (len == values.len) return self.fail(at, "too many arguments", .{});
            values[len] = try self.expression();
            if (values[len].count != 0) return self.fail(at, "arrays cannot be passed as arguments", .{});
            len += 1;
            if (self.eat(.r_paren)) return len;
            _ = try self.expect(.comma, "',' or ')'");
        }
    }
    fn construct(self: *Compiler, ty: Type, at: usize) !Value {
        var args: [16]Value = undefined;
        const len = try self.arguments(&args, at);
        if (ty == .void or ty == .bool) return self.fail(at, "cannot construct {s}", .{ty.name()});
        if (len == 0) return self.fail(at, "{s}() needs arguments", .{ty.name()});
        if (ty == .int or ty == .float) {
            if (len != 1 or (args[0].ty != .int and args[0].ty != .float and args[0].ty != .bool)) return self.fail(at, "{s}() takes one scalar", .{ty.name()});
            const source = args[0];
            if (source.ty == ty or (ty == .int and source.ty == .bool)) return .{ .ty = ty, .reg = source.reg };
            if (ty == .float and source.int_literal != null) return .{ .ty = .float, .reg = try self.floatConstant(@floatFromInt(source.int_literal.?)) };
            const dst = try self.temp(1);
            try self.emit(.{ .op = if (ty == .float) .itof else .ftoi, .dst = dst, .a = source.reg });
            return .{ .ty = ty, .reg = dst };
        }
        const words = ty.words();
        // vecN(x) and matN(x): splat, or a scaled identity for a matrix.
        if (len == 1 and (args[0].ty == .float or args[0].ty == .int)) {
            const scalar = try self.coerce(args[0], .float, at);
            const dst = try self.temp(words);
            if (ty.isMatrix()) {
                try self.emit(.{ .op = .zero, .dst = dst, .c = words });
                const n = ty.order();
                for (0..n) |i| try self.emit(.{ .op = .mov, .dst = dst + @as(u16, @intCast(i * n + i)), .a = scalar.reg });
            } else {
                try self.emit(.{ .op = .splat, .w = @intCast(words), .dst = dst, .a = scalar.reg });
            }
            return .{ .ty = ty, .reg = dst };
        }
        var total: u16 = 0;
        for (args[0..len]) |arg| {
            if (!arg.ty.isFloat() and arg.ty != .int) return self.fail(at, "{s}() takes float components", .{ty.name()});
            if (arg.ty.isMatrix()) return self.fail(at, "{s}() cannot take a matrix", .{ty.name()});
            total += arg.ty.words();
        }
        if (total != words) return self.fail(at, "{s}() needs {d} components, got {d}", .{ ty.name(), words, total });
        const dst = try self.temp(words);
        var offset: u16 = 0;
        for (args[0..len]) |arg| {
            const value = if (arg.ty == .int) try self.coerce(arg, .float, at) else arg;
            try self.emit(.{ .op = .mov, .w = @intCast(value.ty.words()), .dst = dst + offset, .a = value.reg });
            offset += value.ty.words();
        }
        return .{ .ty = ty, .reg = dst };
    }
    fn userCall(self: *Compiler, index: usize, at: usize) !Value {
        var args: [max_params]Value = undefined;
        const len = try self.arguments(&args, at);
        const callee = self.functions.items[index];
        if (self.in_prologue) return self.fail(at, "constants cannot call functions", .{});
        if (len != callee.param_count) return self.fail(at, "'{s}' takes {d} arguments, got {d}", .{ callee.name, callee.param_count, len });
        for (args[0..len], 0..) |arg, i| args[i] = try self.coerce(arg, callee.params[i], at);
        for (args[0..len], 0..) |arg, i| try self.emit(.{ .op = .mov, .w = @intCast(callee.params[i].words()), .dst = callee.param_regs[i], .a = arg.reg });
        try self.emit(.{ .op = .call, .dst = callee.pc, .a = callee.slot });
        self.cost +|= callee.cost;
        if (callee.ret == .void) return .{ .ty = .void, .reg = 0 };
        // Calls share the callee's static result register; copy it out.
        const dst = try self.temp(callee.ret.words());
        try self.emit(.{ .op = .mov, .w = @intCast(callee.ret.words()), .dst = dst, .a = callee.result });
        return .{ .ty = callee.ret, .reg = dst };
    }
    fn builtinCall(self: *Compiler, builtin: Builtin, at: usize) !Value {
        var args: [3]Value = undefined;
        const len = try self.arguments(&args, at);
        const name = self.text(at);
        const arity: usize = switch (builtin) {
            .unary, .length, .normalize => 1,
            .sample => 1,
            .atan => if (len == 2) 2 else 1,
            .binary, .dot, .distance, .cross, .step => 2,
            .clamp, .mix, .smoothstep => 3,
            .min_max => 2,
            .abs => 1,
        };
        if (len != arity) return self.fail(at, "{s} takes {d} arguments", .{ name, arity });
        switch (builtin) {
            .sample => {
                if (self.uses_sample == null) self.uses_sample = at;
                const position = try self.coerce(args[0], .vec2, at);
                const dst = try self.temp(4);
                try self.emit(.{ .op = .sample, .w = 4, .dst = dst, .a = position.reg });
                return .{ .ty = .vec4, .reg = dst };
            },
            .abs => {
                if (args[0].ty == .int) {
                    const dst = try self.temp(1);
                    try self.emit(.{ .op = .iabs, .dst = dst, .a = args[0].reg });
                    return .{ .ty = .int, .reg = dst };
                }
                return self.generic(.fabs, args[0], at);
            },
            .unary => |op| return self.generic(op, args[0], at),
            .atan => {
                if (len == 1) return self.generic(.atan, args[0], at);
                return self.genericBinary(.fatan2, args[0], args[1], false, at);
            },
            .binary => |op| return self.genericBinary(op, args[0], args[1], false, at),
            .min_max => |op| {
                if (args[0].ty == .int and args[1].ty == .int) {
                    const dst = try self.temp(1);
                    try self.emit(.{ .op = if (op == .fmin) .imin else .imax, .dst = dst, .a = args[0].reg, .b = args[1].reg });
                    return .{ .ty = .int, .reg = dst };
                }
                return self.genericBinary(op, args[0], args[1], true, at);
            },
            .step => {
                // step(edge, x): the edge may be a scalar.
                const x = try self.genericOperand(args[1], at);
                const edge = try self.coerceOrScalar(args[0], x.ty, at);
                const dst = try self.temp(x.ty.words());
                try self.emit(.{ .op = .fstep, .w = @intCast(x.ty.words()), .flags = if (edge.ty != x.ty) broadcast_a else 0, .dst = dst, .a = edge.reg, .b = x.reg });
                return .{ .ty = x.ty, .reg = dst };
            },
            .dot, .distance => {
                const pair = try self.unify(args[0], args[1], at);
                if (!pair[0].ty.isGeneric()) return self.fail(at, "{s} takes float vectors", .{name});
                const dst = try self.temp(1);
                try self.emit(.{ .op = if (builtin == .dot) .dot else .distance, .w = @intCast(pair[0].ty.words()), .dst = dst, .a = pair[0].reg, .b = pair[1].reg });
                return .{ .ty = .float, .reg = dst };
            },
            .length => {
                const value = try self.genericOperand(args[0], at);
                const dst = try self.temp(1);
                try self.emit(.{ .op = .length, .w = @intCast(value.ty.words()), .dst = dst, .a = value.reg });
                return .{ .ty = .float, .reg = dst };
            },
            .normalize => return self.generic(.normalize, args[0], at),
            .cross => {
                const a = try self.coerce(args[0], .vec3, at);
                const b = try self.coerce(args[1], .vec3, at);
                const dst = try self.temp(3);
                try self.emit(.{ .op = .cross, .w = 3, .dst = dst, .a = a.reg, .b = b.reg });
                return .{ .ty = .vec3, .reg = dst };
            },
            .clamp => {
                const x = try self.genericOperand(args[0], at);
                const lo = try self.coerceOrScalar(args[1], x.ty, at);
                const hi = try self.coerceOrScalar(args[2], x.ty, at);
                const dst = try self.temp(x.ty.words());
                const flags: u8 = (if (lo.ty != x.ty) broadcast_b else 0) | (if (hi.ty != x.ty) broadcast_c else 0);
                try self.emit(.{ .op = .fclamp, .w = @intCast(x.ty.words()), .flags = flags, .dst = dst, .a = x.reg, .b = lo.reg, .c = hi.reg });
                return .{ .ty = x.ty, .reg = dst };
            },
            .mix => {
                const pair = try self.unify(args[0], args[1], at);
                if (!pair[0].ty.isGeneric()) return self.fail(at, "mix takes float values", .{});
                const t = try self.coerceOrScalar(args[2], pair[0].ty, at);
                const dst = try self.temp(pair[0].ty.words());
                try self.emit(.{ .op = .fmix, .w = @intCast(pair[0].ty.words()), .flags = if (t.ty != pair[0].ty) broadcast_c else 0, .dst = dst, .a = pair[0].reg, .b = pair[1].reg, .c = t.reg });
                return .{ .ty = pair[0].ty, .reg = dst };
            },
            .smoothstep => {
                const x = try self.genericOperand(args[2], at);
                const e0 = try self.coerceOrScalar(args[0], x.ty, at);
                const e1 = try self.coerceOrScalar(args[1], x.ty, at);
                const dst = try self.temp(x.ty.words());
                const flags: u8 = (if (e0.ty != x.ty) broadcast_a else 0) | (if (e1.ty != x.ty) broadcast_b else 0);
                try self.emit(.{ .op = .fsmoothstep, .w = @intCast(x.ty.words()), .flags = flags, .dst = dst, .a = e0.reg, .b = e1.reg, .c = x.reg });
                return .{ .ty = x.ty, .reg = dst };
            },
        }
    }
    fn genericOperand(self: *Compiler, value: Value, at: usize) !Value {
        const result = if (value.ty == .int) try self.coerce(value, .float, at) else value;
        if (!result.ty.isGeneric()) return self.fail(at, "expected float or a float vector, got {s}", .{result.ty.name()});
        return result;
    }
    fn generic(self: *Compiler, op: Op, raw: Value, at: usize) !Value {
        const value = try self.genericOperand(raw, at);
        const dst = try self.temp(value.ty.words());
        try self.emit(.{ .op = op, .w = @intCast(value.ty.words()), .dst = dst, .a = value.reg });
        return .{ .ty = value.ty, .reg = dst };
    }
    fn genericBinary(self: *Compiler, op: Op, raw_a: Value, raw_b: Value, scalar_b: bool, at: usize) !Value {
        const a = try self.genericOperand(raw_a, at);
        const b = if (scalar_b) try self.coerceOrScalar(raw_b, a.ty, at) else try self.coerce(raw_b, a.ty, at);
        const dst = try self.temp(a.ty.words());
        try self.emit(.{ .op = op, .w = @intCast(a.ty.words()), .flags = if (b.ty != a.ty) broadcast_b else 0, .dst = dst, .a = a.reg, .b = b.reg });
        return .{ .ty = a.ty, .reg = dst };
    }
    fn coerceOrScalar(self: *Compiler, value: Value, ty: Type, at: usize) !Value {
        if (value.ty == .float) return value;
        if (value.ty == .int) return self.coerce(value, .float, at);
        return self.coerce(value, ty, at);
    }
    /// Converts an integer literal to float when that is what is expected;
    /// any other type difference is an error.
    fn coerce(self: *Compiler, value: Value, ty: Type, at: usize) !Value {
        if (value.count != 0) return self.fail(at, "an array is not a value", .{});
        if (value.ty == ty) return value;
        if (value.ty == .int and ty == .float) {
            if (value.int_literal) |literal| return .{ .ty = .float, .reg = try self.floatConstant(@floatFromInt(literal)) };
        }
        if (value.ty == .void) return self.fail(at, "this call returns no value", .{});
        return self.fail(at, "expected {s}, got {s}", .{ ty.name(), value.ty.name() });
    }
    fn unify(self: *Compiler, a: Value, b: Value, at: usize) ![2]Value {
        if (a.count != 0 or b.count != 0) return self.fail(at, "arrays cannot be compared or combined", .{});
        if (a.ty == b.ty) return .{ a, b };
        if (a.ty == .int and b.ty.isFloat()) return .{ try self.coerce(a, b.ty, at), b };
        if (b.ty == .int and a.ty.isFloat()) return .{ a, try self.coerce(b, a.ty, at) };
        return self.fail(at, "mismatched types {s} and {s}", .{ a.ty.name(), b.ty.name() });
    }
};

const Builtin = union(enum) {
    unary: Op,
    abs,
    atan,
    binary: Op,
    min_max: Op,
    step,
    dot,
    length,
    distance,
    normalize,
    cross,
    clamp,
    mix,
    smoothstep,
    sample,
};
fn builtinNamed(name: []const u8) ?Builtin {
    const table = .{
        .{ "sin", Builtin{ .unary = .sin } },                 .{ "cos", Builtin{ .unary = .cos } },
        .{ "tan", Builtin{ .unary = .tan } },                 .{ "asin", Builtin{ .unary = .asin } },
        .{ "acos", Builtin{ .unary = .acos } },               .{ "sqrt", Builtin{ .unary = .sqrt } },
        .{ "inversesqrt", Builtin{ .unary = .inversesqrt } }, .{ "exp", Builtin{ .unary = .exp } },
        .{ "log", Builtin{ .unary = .log } },                 .{ "exp2", Builtin{ .unary = .exp2 } },
        .{ "log2", Builtin{ .unary = .log2 } },               .{ "sign", Builtin{ .unary = .sign } },
        .{ "floor", Builtin{ .unary = .floor } },             .{ "ceil", Builtin{ .unary = .ceil } },
        .{ "fract", Builtin{ .unary = .fract } },             .{ "round", Builtin{ .unary = .round } },
        .{ "abs", Builtin.abs },                              .{ "atan", Builtin.atan },
        .{ "pow", Builtin{ .binary = .fpow } },               .{ "mod", Builtin{ .binary = .fmod } },
        .{ "min", Builtin{ .min_max = .fmin } },              .{ "max", Builtin{ .min_max = .fmax } },
        .{ "step", Builtin.step },                            .{ "dot", Builtin.dot },
        .{ "length", Builtin.length },                        .{ "distance", Builtin.distance },
        .{ "normalize", Builtin.normalize },                  .{ "cross", Builtin.cross },
        .{ "clamp", Builtin.clamp },                          .{ "mix", Builtin.mix },
        .{ "smoothstep", Builtin.smoothstep },                .{ "sample", Builtin.sample },
    };
    inline for (table) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}
fn typeNamed(name: []const u8) ?Type {
    inline for (std.meta.fields(Type)) |field| if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    return null;
}
fn isKeyword(name: []const u8) bool {
    const words = [_][]const u8{ "uniform", "const", "if", "else", "for", "while", "do", "return", "break", "continue", "true", "false", "size", "scale" };
    for (words) |word| if (std.mem.eql(u8, name, word)) return true;
    return false;
}
fn symbolOf(tag: Tag) []const u8 {
    return switch (tag) {
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        else => "%",
    };
}
fn parseSwizzle(text: []const u8, width: u16) ?[4]u8 {
    if (text.len == 0 or text.len > 4) return null;
    const sets = [_][]const u8{ "xyzw", "rgba" };
    for (sets) |set| {
        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        var ok = true;
        for (text, 0..) |char, i| {
            const index = std.mem.indexOfScalar(u8, set, char) orelse {
                ok = false;
                break;
            };
            if (index >= width) return null;
            mask[i] = @intCast(index);
        }
        if (ok) return mask;
    }
    return null;
}
fn packMask(mask: [4]u8) u16 {
    return @as(u16, mask[0]) | @as(u16, mask[1]) << 2 | @as(u16, mask[2]) << 4 | @as(u16, mask[3]) << 6;
}
fn uniqueMask(mask: [4]u8, len: u8) bool {
    for (0..len) |i| for (i + 1..len) |j| if (mask[i] == mask[j]) return false;
    return true;
}
fn tripCount(first: i64, relation: Tag, bound: i64, step: i64) ?u64 {
    if (step == 0) return null;
    const holds = struct {
        fn f(value: i64, r: Tag, b: i64) bool {
            return switch (r) {
                .lt => value < b,
                .le => value <= b,
                .gt => value > b,
                .ge => value >= b,
                else => value != b,
            };
        }
    }.f;
    if (!holds(first, relation, bound)) return 0;
    switch (relation) {
        .lt, .le => {
            if (step < 0) return null;
            const limit = if (relation == .lt) bound - first else bound - first + 1;
            return @intCast(@divFloor(limit + step - 1, step));
        },
        .gt, .ge => {
            if (step > 0) return null;
            const limit = if (relation == .gt) first - bound else first - bound + 1;
            return @intCast(@divFloor(limit - step - 1, -step));
        },
        else => {
            const distance = bound - first;
            if (@rem(distance, step) != 0 or (distance > 0) != (step > 0)) return null;
            return @intCast(@divExact(distance, step));
        },
    }
}

fn tokenize(gpa: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);
    var index: usize = 0;
    var line: u32 = 1;
    var line_start: usize = 0;
    while (true) {
        // Skip whitespace and comments.
        while (index < source.len) {
            const char = source[index];
            if (char == '\n') {
                index += 1;
                line += 1;
                line_start = index;
            } else if (char == ' ' or char == '\t' or char == '\r') {
                index += 1;
            } else if (char == '/' and index + 1 < source.len and source[index + 1] == '/') {
                while (index < source.len and source[index] != '\n') index += 1;
            } else if (char == '/' and index + 1 < source.len and source[index + 1] == '*') {
                const open_line = line;
                const open_column: u32 = @intCast(index - line_start + 1);
                index += 2;
                while (true) {
                    if (index + 1 >= source.len) return lexFail(diagnostic, open_line, open_column, "unterminated comment");
                    if (source[index] == '*' and source[index + 1] == '/') {
                        index += 2;
                        break;
                    }
                    if (source[index] == '\n') {
                        line += 1;
                        line_start = index + 1;
                    }
                    index += 1;
                }
            } else break;
        }
        const start = index;
        const column: u32 = @intCast(index - line_start + 1);
        if (index == source.len) {
            try tokens.append(gpa, .{ .tag = .eof, .start = @intCast(start), .end = @intCast(start), .line = line, .column = column });
            return tokens.toOwnedSlice(gpa);
        }
        const char = source[index];
        var tag: Tag = undefined;
        if (std.ascii.isAlphabetic(char) or char == '_') {
            while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or source[index] == '_')) index += 1;
            tag = .ident;
        } else if (std.ascii.isDigit(char) or (char == '.' and index + 1 < source.len and std.ascii.isDigit(source[index + 1]))) {
            var is_float = false;
            while (index < source.len and std.ascii.isDigit(source[index])) index += 1;
            if (index < source.len and source[index] == '.') {
                is_float = true;
                index += 1;
                while (index < source.len and std.ascii.isDigit(source[index])) index += 1;
            }
            if (index < source.len and (source[index] == 'e' or source[index] == 'E')) {
                is_float = true;
                index += 1;
                if (index < source.len and (source[index] == '+' or source[index] == '-')) index += 1;
                if (index == source.len or !std.ascii.isDigit(source[index])) return lexFail(diagnostic, line, column, "malformed exponent");
                while (index < source.len and std.ascii.isDigit(source[index])) index += 1;
            }
            if (index < source.len and (std.ascii.isAlphabetic(source[index]) or source[index] == '_')) return lexFail(diagnostic, line, column, "malformed number");
            tag = if (is_float) .float_lit else .int_lit;
        } else {
            const next: u8 = if (index + 1 < source.len) source[index + 1] else 0;
            const two: ?Tag = switch (char) {
                '<' => if (next == '=') .le else null,
                '>' => if (next == '=') .ge else null,
                '=' => if (next == '=') .eq_eq else null,
                '!' => if (next == '=') .bang_eq else null,
                '&' => if (next == '&') .amp_amp else null,
                '|' => if (next == '|') .pipe_pipe else null,
                '+' => if (next == '=') .plus_eq else if (next == '+') .plus_plus else null,
                '-' => if (next == '=') .minus_eq else if (next == '-') .minus_minus else null,
                '*' => if (next == '=') .star_eq else null,
                '/' => if (next == '=') .slash_eq else null,
                else => null,
            };
            if (two) |value| {
                tag = value;
                index += 2;
            } else {
                tag = switch (char) {
                    '(' => .l_paren,
                    ')' => .r_paren,
                    '{' => .l_brace,
                    '}' => .r_brace,
                    '[' => .l_bracket,
                    ']' => .r_bracket,
                    ',' => .comma,
                    ';' => .semicolon,
                    '.' => .dot,
                    '?' => .question,
                    ':' => .colon,
                    '+' => .plus,
                    '-' => .minus,
                    '*' => .star,
                    '/' => .slash,
                    '%' => .percent,
                    '!' => .bang,
                    '<' => .lt,
                    '>' => .gt,
                    '=' => .assign,
                    else => return lexFail(diagnostic, line, column, "unexpected character"),
                };
                index += 1;
            }
        }
        try tokens.append(gpa, .{ .tag = tag, .start = @intCast(start), .end = @intCast(index), .line = line, .column = column });
    }
}
fn lexFail(diagnostic: *Diagnostic, line: u32, column: u32, message: []const u8) error{InvalidShader} {
    diagnostic.line = line;
    diagnostic.column = column;
    @memcpy(diagnostic.buffer[0..message.len], message);
    diagnostic.len = message.len;
    return error.InvalidShader;
}

/// Compile `source` into an owned Program. On `InvalidShader`, `diagnostic`
/// holds the first error's position and message. Compilation is pure and may
/// run on any thread; the Program may then be used from any one thread at a
/// time.
pub fn compile(gpa: std.mem.Allocator, source: []const u8, options: Options, diagnostic: *Diagnostic) error{ InvalidShader, OutOfMemory }!*Program {
    diagnostic.* = .{};
    if (source.len > max_source_bytes) return lexFail(diagnostic, 1, 1, "source is longer than 64 KiB");
    if (options.max_steps == 0 or options.max_loop == 0) return lexFail(diagnostic, 1, 1, "limits must be positive");
    const tokens = try tokenize(gpa, source, diagnostic);
    defer gpa.free(tokens);
    var self: Compiler = .{ .gpa = gpa, .source = source, .tokens = tokens, .diagnostic = diagnostic, .options = options, .identity = next_identity.fetchAdd(1, .monotonic) };
    defer self.deinit();
    self.program() catch |err| switch (err) {
        error.InvalidShader => return error.InvalidShader,
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    const entry = self.functions.items[self.entry.?];
    // Prologue first, then the function code relocated past it.
    const prologue_len: u16 = @intCast(self.prologue.items.len + 1);
    const code = try gpa.alloc(Instruction, prologue_len + self.main.items.len);
    errdefer gpa.free(code);
    @memcpy(code[0 .. prologue_len - 1], self.prologue.items);
    code[prologue_len - 1] = .{ .op = .halt };
    for (self.main.items, 0..) |instruction, i| {
        var relocated = instruction;
        switch (instruction.op) {
            .jump, .jump_zero, .call => relocated.dst += prologue_len,
            else => {},
        }
        code[prologue_len + i] = relocated;
    }
    const image_len = constant_base + self.constant_words;
    const image = try gpa.dupe(u32, self.image[0..image_len]);
    errdefer gpa.free(image);
    const uniforms = try gpa.dupe(UniformEntry, self.uniforms.items);
    errdefer gpa.free(uniforms);
    const names = try gpa.dupe(u8, self.names.items);
    errdefer gpa.free(names);
    const result = try gpa.create(Program);
    result.* = .{
        .allocator = gpa,
        .identity = self.identity,
        .kind = self.kind,
        .code = code,
        .image = image,
        .prologue_end = prologue_len,
        .entry = entry.pc + prologue_len,
        .entry_slot = entry.slot,
        .position_register = entry.param_regs[0],
        .pixel_register = if (self.kind == .color) entry.param_regs[1] else 0,
        .result_register = entry.result,
        .register_words = self.peak_register,
        .uniform_words = self.uniform_words,
        .uniforms = uniforms,
        .names = names,
        .max_steps = @intCast(entry.cost),
        .prologue_steps = @intCast(self.prologue_cost + 1),
    };
    return result;
}
