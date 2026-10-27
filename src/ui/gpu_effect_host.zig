//! The host code around a translated shader program for the GPU renderers,
//! and the table of programs a renderer has compiled.
//!
//! The host reproduces `shader_effects` per pixel: the same positions, the
//! same exact bilinear sampling of the content (transparent outside an
//! element's capture, clamped to the backdrop's copy), the same fault
//! handling and the same clamping of the result. Element effects run over
//! a capture in place of its filter; backdrop shaders over a copy of the
//! target beneath their shape, writing every pixel of `out`.
const std = @import("std");
const shader = @import("ziggurat_shader");
const shader_effects = @import("shader_effects.zig");

pub const Target = shader_effects.Target;

/// The pass geometry, as the host's `ZsParams` constant buffer holds it.
pub const Params = extern struct {
    /// Element: box x, y (DIP), capture x0, y0 (physical pixel of plane
    /// pixel 0 minus 0.5). Backdrop: box x, y, content x0, y0.
    a: [4]f32 = .{ 0, 0, 0, 0 },
    /// Layer sampling x0, y0, scale, radius (backdrop, physical).
    b: [4]f32 = .{ 0, 0, 0, 0 },
    /// Backdrop: the rounded rectangle, physical left, top, right, bottom.
    shape: [4]f32 = .{ 0, 0, 0, 0 },
    /// Backdrop: the physical clip.
    clip: [4]f32 = .{ 0, 0, 0, 0 },
    /// Backdrop: pixel origin x, y; target pixel of output pixel 0, 0.
    c: [4]f32 = .{ 0, 0, 0, 0 },
    /// Backdrop: target pixel of content pixel 0, 0.
    d: [4]f32 = .{ 0, 0, 0, 0 },
    /// Content width, height; backdrop: 1 for an opaque target.
    plane: [4]u32 = .{ 0, 0, 0, 0 },
};

/// The parameters of an element effect over `capture`.
pub fn elementParams(entry: *const shader_effects.Entry, capture: anytype) Params {
    const x0: f32 = @as(f32, @floatFromInt(capture.left)) - @as(f32, @floatFromInt(capture.radius));
    const y0: f32 = @as(f32, @floatFromInt(capture.top)) - @as(f32, @floatFromInt(capture.radius));
    const scale = capture.scale;
    return .{
        .a = .{ entry.box.x, entry.box.y, x0, y0 },
        .b = .{ x0 - entry.box.x * scale, y0 - entry.box.y * scale, scale, 0 },
        .plane = .{ capture.pixelWidth(), capture.pixelHeight(), 0, 0 },
    };
}
/// The parameters of a backdrop shader planned on a target where physical
/// = DIP * `scale` + `origin`.
pub fn backdropParams(entry: *const shader_effects.Entry, plan: shader_effects.BackdropPlan, scale: f32, origin: [2]f64, clip: [4]f64, transparent: bool) Params {
    const ox: f32 = @floatCast(origin[0]);
    const oy: f32 = @floatCast(origin[1]);
    const rx: f32 = @floatFromInt(plan.region[0]);
    const ry: f32 = @floatFromInt(plan.region[1]);
    const cx = rx - entry.box.x * scale - ox;
    const cy = ry - entry.box.y * scale - oy;
    return .{
        .a = .{ entry.box.x, entry.box.y, cx, cy },
        .b = .{ cx, cy, scale, plan.radius },
        .shape = plan.box,
        .clip = .{ @floatCast(clip[0]), @floatCast(clip[1]), @floatCast(clip[2]), @floatCast(clip[3]) },
        .c = .{ ox, oy, @floatFromInt(plan.out[0]), @floatFromInt(plan.out[1]) },
        .d = .{ rx, ry, 0, 0 },
        .plane = .{ @intCast(plan.region[2] - plan.region[0]), @intCast(plan.region[3] - plan.region[1]), @intFromBool(!transparent), 0 },
    };
}

pub const Language = shader.gpu.Language;

// The body is shared: each language defines the ZH_ macros.
const hlsl_header =
    \\#define ZH_F2 float2
    \\#define ZH_F4 float4
    \\#define ZH_INT(x) ((int)(x))
    \\#define ZH_BITS(x) asuint(x)
    \\#define ZH_TEXEL(x, y) zs_content.Load(int3((x), (y), 0))
    \\cbuffer ZsParams : register(b1) {
    \\    float4 zp_a;
    \\    float4 zp_b;
    \\    float4 zp_shape;
    \\    float4 zp_clip;
    \\    float4 zp_c;
    \\    float4 zp_d;
    \\    uint4 zp_plane;
    \\};
    \\Texture2D<float4> zs_content : register(t0);
    \\
;
const glsl_header =
    \\#define ZH_F2 vec2
    \\#define ZH_F4 vec4
    \\#define ZH_INT(x) int(x)
    \\#define ZH_BITS(x) floatBitsToUint(x)
    \\#define ZH_TEXEL(x, y) texelFetch(zs_content, ivec2((x), (y)), 0)
    \\layout(std140) uniform ZsParams {
    \\    vec4 zp_a;
    \\    vec4 zp_b;
    \\    vec4 zp_shape;
    \\    vec4 zp_clip;
    \\    vec4 zp_c;
    \\    vec4 zp_d;
    \\    uvec4 zp_plane;
    \\};
    \\uniform sampler2D zs_content;
    \\out vec4 zs_out;
    \\
;
const common_prelude =
    \\bool zs_ok(float v) { return (ZH_BITS(v) & 0x7f800000u) != 0x7f800000u; }
    \\bool zs_ok4(ZH_F4 v) { return zs_ok(v.x) && zs_ok(v.y) && zs_ok(v.z) && zs_ok(v.w); }
    \\ZH_F4 zs_load(int x, int y) {
    \\    if (x < 0 || y < 0 || x >= ZH_INT(zp_plane.x) || y >= ZH_INT(zp_plane.y)) return ZH_F4(0.0, 0.0, 0.0, 0.0);
    \\    return ZH_TEXEL(x, y);
    \\}
    \\ZH_F4 zs_plane(float x, float y, bool edge) {
    \\    if (!zs_ok(x) || !zs_ok(y)) return ZH_F4(0.0, 0.0, 0.0, 0.0);
    \\    float lx = x - 0.5;
    \\    float ly = y - 0.5;
    \\    float w = float(zp_plane.x);
    \\    float h = float(zp_plane.y);
    \\    if (edge) {
    \\        lx = clamp(lx, 0.0, w - 1.0);
    \\        ly = clamp(ly, 0.0, h - 1.0);
    \\    } else if (lx <= -1.0 || ly <= -1.0 || lx >= w || ly >= h) return ZH_F4(0.0, 0.0, 0.0, 0.0);
    \\    float fx = floor(lx);
    \\    float fy = floor(ly);
    \\    float tx = lx - fx;
    \\    float ty = ly - fy;
    \\    int ix = ZH_INT(fx);
    \\    int iy = ZH_INT(fy);
    \\    ZH_F4 result = zs_load(ix, iy) * ((1.0 - tx) * (1.0 - ty));
    \\    result += zs_load(ix + 1, iy) * (tx * (1.0 - ty));
    \\    result += zs_load(ix, iy + 1) * ((1.0 - tx) * ty);
    \\    result += zs_load(ix + 1, iy + 1) * (tx * ty);
    \\    return result;
    \\}
    \\
;

/// The complete fragment shader for `translation` of a program of `kind`
/// drawn as `target`: entry point `main` returning SV_Target in HLSL,
/// `main` writing `zs_out` in GLSL (which the host prefixes with its
/// `#version`).
pub fn source(allocator: std.mem.Allocator, translation: *const shader.gpu.Translation, kind: shader.Kind, target: Target, language: Language) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    const vectors = @max((translation.inputs.len + 3) / 4, 1);
    switch (language) {
        .hlsl => {
            try w.writeAll(hlsl_header);
            try w.print("cbuffer ZsWords : register(b0) {{ uint4 zs_words[{d}]; }};\n", .{vectors});
            try w.writeAll("uint zs_input(uint i) { return zs_words[i >> 2][i & 3]; }\n");
        },
        .glsl => {
            try w.writeAll(glsl_header);
            try w.print("layout(std140) uniform ZsWords {{ uvec4 zs_words[{d}]; }};\n", .{vectors});
            try w.writeAll("uint zs_input(uint i) { return zs_words[i >> 2u][i & 3u]; }\n");
        },
    }
    try w.writeAll(common_prelude);
    // Layer programs sample in box-relative DIP.
    try w.print("ZH_F4 zs_sample(ZH_F2 p) {{ return zs_plane(p.x * zp_b.z - zp_b.x, p.y * zp_b.z - zp_b.y, {s}); }}\n", .{if (target == .backdrop) "true" else "false"});
    try w.writeAll(translation.source);
    switch (target) {
        .element => {
            try w.writeAll(
                \\ZH_F4 zs_main(ZH_F4 at) {
                \\    float px = floor(at.x);
                \\    float py = floor(at.y);
                \\    ZH_F2 position = ZH_F2((px + 0.5 + zp_a.z) / zp_b.z - zp_a.x, (py + 0.5 + zp_a.w) / zp_b.z - zp_a.y);
                \\    ZH_F4 result = ZH_F4(0.0, 0.0, 0.0, 0.0);
                \\
            );
            try w.writeAll(switch (kind) {
                .color => "    bool ok = zs_run(position, ZH_TEXEL(ZH_INT(px), ZH_INT(py)), result);\n",
                .distortion =>
                \\    bool ok = zs_run(position, ZH_F4(0.0, 0.0, 0.0, 0.0), result);
                \\    if (ok) ok = zs_ok(result.x) && zs_ok(result.y);
                \\    if (ok) result = zs_plane((result.x + zp_a.x) * zp_b.z - zp_a.z, (result.y + zp_a.y) * zp_b.z - zp_a.w, false);
                \\
                ,
                .layer => "    bool ok = zs_run(position, ZH_F4(0.0, 0.0, 0.0, 0.0), result);\n",
            });
            try w.writeAll(
                \\    if (!ok || !zs_ok4(result)) return ZH_F4(0.0, 0.0, 0.0, 0.0);
                \\    float a = clamp(result.a, 0.0, 1.0);
                \\    return ZH_F4(clamp(result.rgb, 0.0, a), a);
                \\}
                \\
            );
        },
        .backdrop => {
            try w.writeAll(
                \\ZH_F4 zs_main(ZH_F4 at) {
                \\    float x = floor(at.x) + zp_c.z;
                \\    float y = floor(at.y) + zp_c.w;
                \\    ZH_F4 beneath = ZH_TEXEL(ZH_INT(x - zp_d.x), ZH_INT(y - zp_d.y));
                \\    float px = x + 0.5;
                \\    float py = y + 0.5;
                \\    float radius = zp_b.w;
                \\    float hx = (zp_shape.z - zp_shape.x) / 2.0;
                \\    float hy = (zp_shape.w - zp_shape.y) / 2.0;
                \\    float qx = abs(px - (zp_shape.x + hx)) - (hx - radius);
                \\    float qy = abs(py - (zp_shape.y + hy)) - (hy - radius);
                \\    float distance = sqrt(max(qx, 0.0) * max(qx, 0.0) + max(qy, 0.0) * max(qy, 0.0)) + min(max(qx, qy), 0.0) - radius;
                \\    float cover = max(0.0, min(x + 1.0, zp_clip.z) - max(x, zp_clip.x)) * max(0.0, min(y + 1.0, zp_clip.w) - max(y, zp_clip.y));
                \\    float amount = clamp(0.5 - distance, 0.0, 1.0) * cover;
                \\    if (amount == 0.0) return beneath;
                \\    ZH_F2 position = ZH_F2((px - zp_c.x) / zp_b.z - zp_a.x, (py - zp_c.y) / zp_b.z - zp_a.y);
                \\    ZH_F4 result = ZH_F4(0.0, 0.0, 0.0, 0.0);
                \\
            );
            try w.writeAll(switch (kind) {
                .color => "    bool ok = zs_run(position, beneath, result);\n",
                .distortion =>
                \\    bool ok = zs_run(position, ZH_F4(0.0, 0.0, 0.0, 0.0), result);
                \\    if (ok) ok = zs_ok(result.x) && zs_ok(result.y);
                \\    if (ok) result = zs_plane(result.x * zp_b.z - zp_a.z, result.y * zp_b.z - zp_a.w, true);
                \\
                ,
                .layer => "    bool ok = zs_run(position, ZH_F4(0.0, 0.0, 0.0, 0.0), result);\n",
            });
            try w.writeAll(
                \\    if (!ok || !zs_ok4(result)) return beneath;
                \\    float a = clamp(result.a, 0.0, 1.0);
                \\    ZH_F4 over = clamp(result, 0.0, 1.0) + beneath * (1.0 - a);
                \\    ZH_F4 mixed = beneath + (over - beneath) * amount;
                \\    if (zp_plane.z != 0u) mixed.a = 1.0;
                \\    float ma = clamp(mixed.a, 0.0, 1.0);
                \\    return ZH_F4(clamp(mixed.rgb, 0.0, ma), ma);
                \\}
                \\
            );
        },
    }
    try w.writeAll(switch (language) {
        .hlsl => "float4 main(float4 at : SV_Position) : SV_Target { return zs_main(at); }\n",
        .glsl => "void main() { zs_out = zs_main(gl_FragCoord); }\n",
    });
    return out.toOwnedSliceSentinel(0);
}

/// Pixel shaders one renderer keeps installed.
pub const slots = 16;
comptime {
    std.debug.assert(slots >= shader_effects.max_entries);
}

/// Which program each installed pixel shader runs, with the inputs its
/// words are gathered from, and the programs that failed to compile.
pub const Table = struct {
    pub const Slot = struct {
        identity: u64 = 0,
        target: Target = .element,
        inputs: []u16 = &.{},
        /// The compiled bytecode, kept to install again after a device loss.
        code: []u8 = &.{},
        allocator: ?std.mem.Allocator = null,
        used: u64 = 0,
    };
    const Failure = struct { identity: u64 = 0, target: Target = .element };
    entries: [slots]Slot = @splat(.{}),
    failures: [slots]Failure = @splat(.{}),
    next_failure: usize = 0,
    clock: u64 = 0,

    pub fn deinit(self: *Table) void {
        for (&self.entries) |*slot| self.clear(slot);
        self.* = .{};
    }
    fn clear(_: *Table, slot: *Slot) void {
        if (slot.allocator) |allocator| {
            allocator.free(slot.inputs);
            allocator.free(slot.code);
        }
        slot.* = .{};
    }
    /// Starts a frame: slots found or filled after this are kept for it.
    pub fn beginFrame(self: *Table) void {
        self.clock += 1;
    }
    pub fn find(self: *Table, identity: u64, target: Target) ?u32 {
        for (&self.entries, 0..) |*slot, i| if (slot.identity == identity and slot.target == target and slot.identity != 0) {
            slot.used = self.clock;
            return @intCast(i);
        };
        return null;
    }
    pub fn failed(self: *const Table, identity: u64, target: Target) bool {
        for (self.failures) |failure| if (failure.identity == identity and failure.target == target and identity != 0) return true;
        return false;
    }
    pub fn fail(self: *Table, identity: u64, target: Target) void {
        self.failures[self.next_failure] = .{ .identity = identity, .target = target };
        self.next_failure = (self.next_failure + 1) % slots;
    }
    /// The slot to fill: an empty one, else the least recently used one not
    /// used this frame, emptied.
    pub fn victim(self: *Table) ?u32 {
        var best: ?usize = null;
        for (self.entries, 0..) |slot, i| {
            if (slot.identity == 0) {
                best = i;
                break;
            }
            if (slot.used == self.clock) continue;
            if (best == null or slot.used < self.entries[best.?].used) best = i;
        }
        const index = best orelse return null;
        self.clear(&self.entries[index]);
        return @intCast(index);
    }
    /// Record `slot` as running the program `identity` drawn as `target`;
    /// the table owns `inputs` and `code`, allocated with `allocator`.
    pub fn fill(self: *Table, slot: u32, identity: u64, target: Target, inputs: []u16, code: []u8, allocator: std.mem.Allocator) void {
        self.entries[slot] = .{ .identity = identity, .target = target, .inputs = inputs, .code = code, .allocator = allocator, .used = self.clock };
    }
};

test "the table keeps a frame's slots and replaces the least recently used" {
    const allocator = std.testing.allocator;
    var table: Table = .{};
    defer table.deinit();
    table.beginFrame();
    for (0..slots) |i| {
        const slot = table.victim().?;
        table.fill(slot, i + 1, .element, try allocator.dupe(u16, &.{@intCast(i)}), try allocator.dupe(u8, "DXBC"), allocator);
    }
    // Every slot is used this frame.
    try std.testing.expect(table.victim() == null);
    table.beginFrame();
    try std.testing.expectEqual(@as(?u32, 3), table.find(4, .element));
    try std.testing.expect(table.find(4, .backdrop) == null);
    const slot = table.victim().?;
    try std.testing.expect(slot != 3);
    try std.testing.expect(table.find(slot + 1, .element) == null);
    table.fail(99, .backdrop);
    try std.testing.expect(table.failed(99, .backdrop));
    try std.testing.expect(!table.failed(99, .element));
}

test "host source wraps a translation for each kind, target and language" {
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{
        "vec4 color(vec2 p, vec4 c) { return c * 0.5; }",
        "vec2 distort(vec2 p) { return p + vec2(1.0, 0.0); }",
        "vec4 layer(vec2 p) { return sample(p + vec2(2.0)); }",
    };
    for (sources) |text_source| {
        var diagnostic: shader.Diagnostic = .{};
        const program = try shader.compile(allocator, text_source, .{}, &diagnostic);
        defer program.destroy();
        for ([_]Language{ .hlsl, .glsl }) |language| {
            var translation = try shader.gpu.translate(allocator, program, language);
            defer translation.deinit();
            for ([_]Target{ .element, .backdrop }) |target| {
                const text = try source(allocator, &translation, program.kind, target, language);
                defer allocator.free(text);
                try std.testing.expect(std.mem.indexOf(u8, text, if (language == .hlsl) "float4 main(float4 at : SV_Position) : SV_Target" else "void main()") != null);
                try std.testing.expect(std.mem.indexOf(u8, text, "bool zs_run(") != null);
                try std.testing.expect(std.mem.indexOf(u8, text, "zs_plane(") != null);
            }
        }
    }
}
