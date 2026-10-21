//! Programmable effects run by the shader machine on the software planes.
//! An element effect rewrites what an element and its children drew, after
//! they were captured in isolation with a transparent margin around the
//! box. A backdrop shader rewrites what lies beneath a rounded rectangle.
//! Frames that hold either are replayed in software.
const std = @import("std");
pub const shader = @import("ziggurat_shader");
const layout = @import("layout.zig");
const cpu = @import("cpu_gradient.zig");
const gaussian_kernel = @import("gaussian_kernel.zig");
const gaussian_scope = @import("gaussian_scope.zig");
const drawing = @import("ziggurat_drawing_resources");
pub const Rect = layout.Rect;
pub const Dirty = cpu.Dirty;

/// Effects one Buffer can hold.
pub const max_entries = 16;
/// Largest margin around an element's box, in physical pixels.
pub const max_margin_pixels = 256;

/// A compiled program and its uniform values. Recording copies the values;
/// the program must stay alive until the frame that records it has painted.
pub const Effect = struct {
    program: *const shader.Program,
    values: *const shader.Values,
    /// DIP around the element's box that the effect may read and draw into.
    /// Content drawn beyond it reads as transparent. Backdrop shaders read
    /// this far beyond their shape but draw only inside it.
    margin: f32 = 0,
};

pub const Target = enum(u8) { element, backdrop };
/// A program a GPU renderer prepares to draw as `target`; see
/// `Context.prepareGpuShaders`.
pub const GpuShader = struct { program: *const shader.Program, target: Target };
/// One recorded effect in absolute DIP.
pub const Entry = struct {
    program: *const shader.Program,
    values: shader.Values,
    target: Target,
    /// An element effect's opacity as it composites into its parent.
    opacity: u8 = 255,
    /// The element's box, or the backdrop shader's shape.
    box: Rect,
    margin: f32 = 0,
    radius: f32 = 0,
    /// Physical pixels per DIP of the frame that records an element
    /// effect; selects the capture kernel (see `Workspace.carrierFor`).
    scale: f32 = 1,
    pub fn captureBounds(self: Entry) Rect {
        return .{ .x = self.box.x - self.margin, .y = self.box.y - self.margin, .width = self.box.width + 2 * self.margin, .height = self.box.height + 2 * self.margin };
    }
    pub fn captureRect(self: Entry) drawing.Rect {
        const r = self.captureBounds();
        return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
    }
};

/// The kernel whose capture an element effect borrows: radius one pixel and
/// a single centre weight. Its filter never runs.
pub fn carrier(scale: f32) !gaussian_kernel.Kernel {
    return gaussian_kernel.Kernel.prepare(.{ .sigma = 0.5 / (3 * scale), .scale = scale });
}

pub const Options = struct {
    /// Pixels times worst-case program steps one frame may spend. An effect
    /// that would exceed it draws its content unchanged and counts as skipped.
    max_work: u64 = 256 * 1024 * 1024,
    /// Largest element capture, in physical pixels, that can be isolated
    /// without a Gaussian workspace (see `twoPassRegion`).
    max_pixels: u32 = 1024 * 1024,
};
/// Largest total of the workspace's planes.
pub const max_bytes = 256 * 1024 * 1024;
pub const Stats = struct {
    applied: u64 = 0,
    /// Effects drawn without their program because the frame's work budget
    /// or the backdrop workspace was exhausted.
    skipped: u64 = 0,
    /// Pixels whose run faulted or produced a non-finite value; they become
    /// transparent (or keep the backdrop).
    faulted_pixels: u64 = 0,
    pixels: u64 = 0,
    /// Worst-case work charged, in pixel steps.
    work: u64 = 0,
};

/// Machine, isolation planes and accounting, allocated once by `create`.
/// Replay never allocates.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    machine: shader.Machine = .{},
    options: Options,
    stats: Stats = .{},
    frame_work: u64 = 0,
    /// Saved target, content over black and content over white.
    planes: []u32,
    /// An isolation is in progress; nested ones draw plainly.
    isolating: bool = false,
    /// The capture kernel for `carrier_scale`, kept here so command
    /// entries stay small and the kernel stays put while a capture is open.
    carrier_kernel: gaussian_kernel.Kernel = undefined,
    carrier_scale: f32 = 0,

    /// The kernel whose capture an element effect at `scale` borrows. It is
    /// prepared when the scale changes, outside any open capture.
    pub fn carrierFor(self: *Workspace, scale: f32) !*const gaussian_kernel.Kernel {
        if (self.carrier_scale != scale) {
            self.carrier_kernel = try carrier(scale);
            self.carrier_scale = scale;
        }
        return &self.carrier_kernel;
    }
    pub fn bytesFor(options: Options) !usize {
        if (options.max_work == 0 or options.max_pixels == 0) return error.InvalidShaderEffectOptions;
        const bytes = std.math.mul(usize, @as(usize, options.max_pixels) * 3, 4) catch return error.ShaderEffectBudgetExceeded;
        if (bytes > max_bytes) return error.ShaderEffectBudgetExceeded;
        return bytes + @sizeOf(Workspace);
    }
    pub fn create(allocator: std.mem.Allocator, options: Options) !*Workspace {
        _ = try bytesFor(options);
        const self = try allocator.create(Workspace);
        errdefer allocator.destroy(self);
        const planes = try allocator.alloc(u32, @as(usize, options.max_pixels) * 3);
        self.* = .{ .allocator = allocator, .options = options, .planes = planes };
        return self;
    }
    pub fn destroy(self: *Workspace) void {
        self.allocator.free(self.planes);
        self.allocator.destroy(self);
    }
    fn plane(self: *Workspace, index: usize, region: Region) Plane {
        const len = region.width() * region.height();
        return .{ .pixels = self.planes[index * self.options.max_pixels ..][0..len], .width = region.width(), .height = region.height(), .stride = region.width() };
    }
    /// Starts a frame's work budget.
    pub fn beginFrame(self: *Workspace) void {
        self.frame_work = 0;
    }
    fn charge(self: *Workspace, pixels: u64, program: *const shader.Program) bool {
        const work = std.math.mul(u64, pixels, @max(program.max_steps, 1) + program.prologue_steps) catch return false;
        const total = std.math.add(u64, self.frame_work, work) catch return false;
        if (total > self.options.max_work) {
            self.stats.skipped += 1;
            return false;
        }
        self.frame_work = total;
        self.stats.work += work;
        self.stats.pixels += pixels;
        return true;
    }
};

/// A Buffer's effect table and the workspace bound for one replay.
pub const Storage = struct {
    entries: [max_entries]Entry = undefined,
    len: usize = 0,
    workspace: ?*Workspace = null,
};

pub fn validate(entry: Entry) !void {
    const b = entry.box;
    if (!layout.validRect(b) or !std.math.isFinite(b.x + b.width) or !std.math.isFinite(b.y + b.height) or !std.math.isFinite(entry.margin) or entry.margin < 0 or !std.math.isFinite(entry.radius) or entry.radius < 0) return error.InvalidGeometry;
    if (entry.values.program != entry.program.identity or entry.values.len != entry.program.uniform_words) return error.UniformMismatch;
}

/// A premultiplied plane in physical pixels.
pub const Plane = struct {
    pixels: []u32,
    width: usize,
    height: usize,
    stride: usize,
    fn read(self: Plane, x: usize, y: usize) u32 {
        return self.pixels[y * self.stride + x];
    }
    /// Bilinear sample at a physical position; outside reads `edge`.
    fn sample(self: Plane, x: f32, y: f32, clamp: bool) [4]f32 {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return .{ 0, 0, 0, 0 };
        var lx = x - 0.5;
        var ly = y - 0.5;
        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);
        if (clamp) {
            lx = std.math.clamp(lx, 0, w - 1);
            ly = std.math.clamp(ly, 0, h - 1);
        } else if (lx <= -1 or ly <= -1 or lx >= w or ly >= h) return .{ 0, 0, 0, 0 };
        const fx = @floor(lx);
        const fy = @floor(ly);
        const tx = lx - fx;
        const ty = ly - fy;
        const ix: isize = @intFromFloat(fx);
        const iy: isize = @intFromFloat(fy);
        var result: [4]f32 = .{ 0, 0, 0, 0 };
        inline for (.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |offset| {
            const px = ix + offset[0];
            const py = iy + offset[1];
            const weight = (if (offset[0] == 0) 1 - tx else tx) * (if (offset[1] == 0) 1 - ty else ty);
            if (weight != 0 and px >= 0 and py >= 0 and px < self.width and py < self.height) {
                const c = toColor(self.read(@intCast(px), @intCast(py)));
                for (0..4) |i| result[i] += c[i] * weight;
            }
        }
        return result;
    }
};
/// Premultiplied R, G, B, A in 0..1 from a packed pixel.
pub fn toColor(pixel: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((pixel >> 16) & 255)) / 255,
        @as(f32, @floatFromInt((pixel >> 8) & 255)) / 255,
        @as(f32, @floatFromInt(pixel & 255)) / 255,
        @as(f32, @floatFromInt(pixel >> 24)) / 255,
    };
}
/// A packed premultiplied pixel; alpha clamps to 0..1 and color to alpha.
pub fn fromColor(color: [4]f32) u32 {
    const a = std.math.clamp(color[3], 0, 1);
    var result: u32 = @as(u32, @intFromFloat(@round(a * 255))) << 24;
    inline for (.{ 16, 8, 0 }, 0..) |shift, i| result |= @as(u32, @intFromFloat(@round(std.math.clamp(color[i], 0, a) * 255))) << shift;
    return result;
}
fn finite(color: anytype) bool {
    for (color) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

const SampleContext = struct { plane: Plane, scale: f32, x0: f32, y0: f32, clamp: bool };
fn sampleDip(context: *const anyopaque, x: f32, y: f32) [4]f32 {
    const self: *const SampleContext = @ptrCast(@alignCast(context));
    return self.plane.sample(x * self.scale - self.x0, y * self.scale - self.y0, self.clamp);
}

/// Run `entry` over an element's captured content. `source` holds the
/// capture (box, margin and halo) and is rewritten in place; `scratch` is a
/// plane at least as large. Without a workspace, or over budget, the content
/// stays as drawn.
pub fn applyElement(entry: *const Entry, source: Plane, scratch: Plane, capture: gaussian_scope.Capture, workspace: ?*Workspace) void {
    const x0: f32 = @as(f32, @floatFromInt(capture.left)) - @as(f32, @floatFromInt(capture.radius));
    const y0: f32 = @as(f32, @floatFromInt(capture.top)) - @as(f32, @floatFromInt(capture.radius));
    runContent(entry, source, scratch, x0, y0, capture.scale, workspace);
}
/// Plane pixel (px, py) shows absolute DIP ((px + 0.5 + x0) / scale, ...).
fn runContent(entry: *const Entry, source: Plane, scratch: Plane, x0: f32, y0: f32, scale: f32, workspace: ?*Workspace) void {
    const space = workspace orelse return;
    if (!startElement(space, entry, @as(u64, source.width) * source.height, scale)) return;
    const machine = &space.machine;
    const kind = entry.program.kind;
    if (kind != .color) for (0..source.height) |y| @memcpy(scratch.pixels[y * scratch.stride ..][0..source.width], source.pixels[y * source.stride ..][0..source.width]);
    const content: SampleContext = .{ .plane = scratch, .scale = scale, .x0 = x0, .y0 = y0, .clamp = false };
    const relative = shifted(content, entry.box);
    for (0..source.height) |py| for (0..source.width) |px| {
        const position = [2]f32{
            (@as(f32, @floatFromInt(px)) + 0.5 + x0) / scale - entry.box.x,
            (@as(f32, @floatFromInt(py)) + 0.5 + y0) / scale - entry.box.y,
        };
        const at = py * source.stride + px;
        const color: [4]f32 = switch (kind) {
            .color => machine.color(position, toColor(source.pixels[at])) catch null,
            .distortion => if (machine.distort(position)) |read| (if (finite(read)) content.plane.sample((read[0] + entry.box.x) * scale - x0, (read[1] + entry.box.y) * scale - y0, false) else null) else |_| null,
            .layer => machine.layer(position, .{ .context = &relative, .function = sampleDip }) catch null,
        } orelse .{ std.math.nan(f32), 0, 0, 0 };
        if (!finite(color)) {
            space.stats.faulted_pixels += 1;
            source.pixels[at] = 0;
        } else source.pixels[at] = fromColor(color);
    };
}
/// Charge an element effect over `pixels` captured pixels and run its
/// prologue on the workspace's machine. False leaves the content as drawn:
/// the frame's work budget is spent or the prologue faults.
pub fn startElement(space: *Workspace, entry: *const Entry, pixels: u64, scale: f32) bool {
    if (!space.charge(pixels, entry.program)) return false;
    space.machine.begin(entry.program, &entry.values, .{ entry.box.width, entry.box.height }, scale) catch {
        space.stats.faulted_pixels += pixels;
        return false;
    };
    space.stats.applied += 1;
    return true;
}
/// Physical pixels of a plane: columns x0..x1 and rows y0..y1.
pub const Region = struct {
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    pub fn width(self: Region) usize {
        return self.x1 - self.x0;
    }
    pub fn height(self: Region) usize {
        return self.y1 - self.y0;
    }
};

/// Without a Gaussian workspace an element is isolated on the target plane
/// itself: its pixels under the capture are saved, the body is drawn twice,
/// over opaque black and over opaque white, the saved pixels are restored
/// and the content's premultiplied color and coverage are recovered from
/// the two results. Antialiased edges of the same coverage in every channel
/// are recovered exactly; text with per-channel coverage is averaged.
///
/// The capture region on `surface`, or null when it is empty, larger than
/// the workspace or an isolation is already in progress; the body is then
/// drawn plainly.
pub fn twoPassRegion(surface: cpu.Surface, entry: *const Entry, workspace: *Workspace) ?Region {
    if (workspace.isolating) return null;
    const r = entry.captureBounds();
    const s: f64 = surface.scale;
    const x0 = @max(@floor(@as(f64, r.x) * s + surface.origin[0]), 0);
    const y0 = @max(@floor(@as(f64, r.y) * s + surface.origin[1]), 0);
    const x1 = @min(@ceil((@as(f64, r.x) + r.width) * s + surface.origin[0]), @as(f64, @floatFromInt(surface.width)));
    const y1 = @min(@ceil((@as(f64, r.y) + r.height) * s + surface.origin[1]), @as(f64, @floatFromInt(surface.height)));
    if (!(x1 > x0 and y1 > y0)) return null;
    const region: Region = .{ .x0 = @intFromFloat(x0), .y0 = @intFromFloat(y0), .x1 = @intFromFloat(x1), .y1 = @intFromFloat(y1) };
    if (region.width() * region.height() > workspace.options.max_pixels) {
        workspace.stats.skipped += 1;
        return null;
    }
    return region;
}
fn copyOut(surface: cpu.Surface, region: Region, into: Plane) void {
    for (0..region.height()) |row| @memcpy(into.pixels[row * into.stride ..][0..region.width()], surface.pixels[(region.y0 + row) * surface.stride + region.x0 ..][0..region.width()]);
}
fn fillRegion(surface: cpu.Surface, region: Region, value: u32) void {
    for (region.y0..region.y1) |y| @memset(surface.pixels[y * surface.stride + region.x0 ..][0..region.width()], value);
}
/// Save the region and paint it opaque black for the first pass.
pub fn beginIsolation(surface: cpu.Surface, region: Region, workspace: *Workspace) void {
    workspace.isolating = true;
    copyOut(surface, region, workspace.plane(0, region));
    fillRegion(surface, region, 0xff000000);
}
/// Keep the first pass and paint the region opaque white for the second.
pub fn secondIsolation(surface: cpu.Surface, region: Region, workspace: *Workspace) void {
    copyOut(surface, region, workspace.plane(1, region));
    fillRegion(surface, region, 0xffffffff);
}
/// Abandon an isolation after a failed pass, restoring the target.
pub fn cancelIsolation(surface: cpu.Surface, region: Region, workspace: *Workspace) void {
    if (!workspace.isolating) return;
    workspace.isolating = false;
    const saved = workspace.plane(0, region);
    for (0..region.height()) |row| @memcpy(surface.pixels[(region.y0 + row) * surface.stride + region.x0 ..][0..region.width()], saved.pixels[row * saved.stride ..][0..region.width()]);
}
/// Recover the content, run the effect over it and composite the result
/// over the restored target inside the surface's clip at the entry's
/// opacity. `surface` must hold the second (white) pass.
pub fn finishIsolation(surface: cpu.Surface, transparent: bool, region: Region, entry: *const Entry, workspace: *Workspace) Dirty {
    const black = workspace.plane(1, region);
    const white = workspace.plane(2, region);
    copyOut(surface, region, white);
    cancelIsolation(surface, region, workspace);
    // Over black the result is the premultiplied color; the difference
    // between the passes is what the content let through.
    for (black.pixels, white.pixels) |*b, w| {
        const bc = toColor(b.*);
        const wc = toColor(w);
        var through: f32 = 0;
        for (0..3) |i| through += std.math.clamp(wc[i] - bc[i], 0, 1);
        const alpha = 1 - through / 3;
        b.* = fromColor(.{ bc[0], bc[1], bc[2], alpha });
    }
    const scale = surface.scale;
    const x0: f32 = @as(f32, @floatFromInt(region.x0)) - @as(f32, @floatCast(surface.origin[0]));
    const y0: f32 = @as(f32, @floatFromInt(region.y0)) - @as(f32, @floatCast(surface.origin[1]));
    runContent(entry, black, white, x0, y0, scale, workspace);
    const opacity = @as(f32, @floatFromInt(entry.opacity)) / 255;
    const clip = surface.clip;
    for (region.y0..region.y1) |y| for (region.x0..region.x1) |x| {
        const fx: f64 = @floatFromInt(x);
        const fy: f64 = @floatFromInt(y);
        const cover: f32 = @floatCast(@max(0, @min(fx + 1, clip[2]) - @max(fx, clip[0])) * @max(0, @min(fy + 1, clip[3]) - @max(fy, clip[1])));
        const amount = cover * opacity;
        if (amount == 0) continue;
        const source = toColor(black.pixels[(y - region.y0) * black.stride + x - region.x0]);
        if (source[3] == 0) continue;
        const at = y * surface.stride + x;
        const beneath = toColor(surface.pixels[at]);
        var mixed: [4]f32 = undefined;
        for (0..4) |i| mixed[i] = source[i] * amount + beneath[i] * (1 - source[3] * amount);
        if (!transparent) mixed[3] = 1;
        surface.pixels[at] = fromColor(mixed);
    };
    return .{ .left = @intCast(region.x0), .top = @intCast(region.y0), .right = @intCast(region.x1), .bottom = @intCast(region.y1) };
}

/// Sampling in the program's box-relative DIP.
fn shifted(context: SampleContext, box: Rect) SampleContext {
    var result = context;
    result.x0 -= box.x * context.scale;
    result.y0 -= box.y * context.scale;
    return result;
}

/// Where a backdrop shader draws on a target, in physical pixels: its
/// rounded rectangle, the pixels it writes (`out`, inside the clip) and the
/// pixels it reads (`region`, `out` plus the margin).
pub const BackdropPlan = struct {
    box: [4]f32,
    radius: f32,
    out: [4]usize,
    region: [4]usize,
    pub fn pixels(self: BackdropPlan) u64 {
        return @as(u64, self.out[2] - self.out[0]) * (self.out[3] - self.out[1]);
    }
    pub fn regionPixels(self: BackdropPlan) usize {
        return (self.region[2] - self.region[0]) * (self.region[3] - self.region[1]);
    }
    pub fn dirty(self: BackdropPlan) Dirty {
        return .{ .left = @intCast(self.out[0]), .top = @intCast(self.out[1]), .right = @intCast(self.out[2]), .bottom = @intCast(self.out[3]) };
    }
};
/// The plan for `entry` on a `width` x `height` target where physical =
/// DIP * `scale` + `origin`, or null when nothing is drawn.
pub fn planBackdrop(width: usize, height: usize, scale: f32, origin: [2]f64, clip: [4]f64, entry: *const Entry) ?BackdropPlan {
    const s = scale;
    const b = entry.box;
    const ox: f32 = @floatCast(origin[0]);
    const oy: f32 = @floatCast(origin[1]);
    const box = [4]f32{ @round(b.x * s + ox), @round(b.y * s + oy), @round((b.x + b.width) * s + ox), @round((b.y + b.height) * s + oy) };
    if (!(box[2] > box[0] and box[3] > box[1])) return null;
    const radius = @min(entry.radius * s, @min(box[2] - box[0], box[3] - box[1]) / 2);
    const fw: f32 = @floatFromInt(width);
    const fh: f32 = @floatFromInt(height);
    const fx0 = @max(@max(box[0], @as(f32, @floatCast(@floor(clip[0])))), 0);
    const fy0 = @max(@max(box[1], @as(f32, @floatCast(@floor(clip[1])))), 0);
    const fx1 = @min(@min(box[2], @as(f32, @floatCast(@ceil(clip[2])))), fw);
    const fy1 = @min(@min(box[3], @as(f32, @floatCast(@ceil(clip[3])))), fh);
    if (!(fx1 > fx0 and fy1 > fy0)) return null;
    const out = [4]usize{ @intFromFloat(fx0), @intFromFloat(fy0), @intFromFloat(fx1), @intFromFloat(fy1) };
    const reach: usize = @intFromFloat(@min(@ceil(entry.margin * s), max_margin_pixels));
    return .{ .box = box, .radius = radius, .out = out, .region = .{ out[0] -| reach, out[1] -| reach, @min(out[2] + reach, width), @min(out[3] + reach, height) } };
}
/// Charge a backdrop shader and run its prologue. `room` is how many
/// pixels the backdrop workspace can copy, null without one. False leaves
/// the backdrop unchanged.
pub fn startBackdrop(space: *Workspace, entry: *const Entry, plan: BackdropPlan, room: ?usize, scale: f32) bool {
    const available = room orelse {
        space.stats.skipped += 1;
        return false;
    };
    if (plan.regionPixels() > available) {
        space.stats.skipped += 1;
        return false;
    }
    if (!space.charge(plan.pixels(), entry.program)) return false;
    space.machine.begin(entry.program, &entry.values, .{ entry.box.width, entry.box.height }, scale) catch {
        space.stats.faulted_pixels += plan.pixels();
        return false;
    };
    space.stats.applied += 1;
    return true;
}

/// Run a backdrop shader over what the surface holds beneath `entry.box`,
/// writing inside its rounded rectangle and the surface's clip. Reads beyond
/// the plane repeat its nearest pixel. `scratch` must hold the shape plus
/// margin; without a workspace or room, the backdrop stays unchanged.
pub fn applyBackdrop(surface: cpu.Surface, transparent: bool, entry: *const Entry, scratch: ?[]u32, workspace: ?*Workspace) Dirty {
    const empty: Dirty = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const s: f32 = surface.scale;
    const b = entry.box;
    const ox: f32 = @floatCast(surface.origin[0]);
    const oy: f32 = @floatCast(surface.origin[1]);
    const clip = surface.clip;
    const plan = planBackdrop(surface.width, surface.height, s, surface.origin, clip, entry) orelse return empty;
    const box = plan.box;
    const radius = plan.radius;
    const out = plan.out;
    const region = plan.region;
    const space = workspace orelse return empty;
    if (!startBackdrop(space, entry, plan, if (scratch) |storage| storage.len else null, s)) return empty;
    const storage = scratch.?;
    const rw = region[2] - region[0];
    const rh = region[3] - region[1];
    const machine = &space.machine;
    for (0..rh) |row| @memcpy(storage[row * rw ..][0..rw], surface.pixels[(region[1] + row) * surface.stride + region[0] ..][0..rw]);
    const plane: Plane = .{ .pixels = storage[0 .. rw * rh], .width = rw, .height = rh, .stride = rw };
    const rx: f32 = @floatFromInt(region[0]);
    const ry: f32 = @floatFromInt(region[1]);
    // Box-relative DIP to the copied plane's pixels.
    const content: SampleContext = .{ .plane = plane, .scale = s, .x0 = rx - b.x * s - ox, .y0 = ry - b.y * s - oy, .clamp = true };
    const hx = (box[2] - box[0]) / 2;
    const hy = (box[3] - box[1]) / 2;
    for (out[1]..out[3]) |y| for (out[0]..out[2]) |x| {
        const px = @as(f32, @floatFromInt(x)) + 0.5;
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const qx = @abs(px - (box[0] + hx)) - (hx - radius);
        const qy = @abs(py - (box[1] + hy)) - (hy - radius);
        const distance = @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - radius;
        const fxf: f64 = @floatFromInt(x);
        const fyf: f64 = @floatFromInt(y);
        const cover = @as(f32, @floatCast(@max(0, @min(fxf + 1, clip[2]) - @max(fxf, clip[0])) * @max(0, @min(fyf + 1, clip[3]) - @max(fyf, clip[1]))));
        const amount = std.math.clamp(0.5 - distance, 0, 1) * cover;
        if (amount == 0) continue;
        const position = [2]f32{ (px - ox) / s - b.x, (py - oy) / s - b.y };
        const at = y * surface.stride + x;
        const beneath = toColor(surface.pixels[at]);
        const result: ?[4]f32 = switch (entry.program.kind) {
            .color => machine.color(position, beneath) catch null,
            .distortion => if (machine.distort(position)) |read| (if (finite(read)) content.plane.sample(read[0] * s - content.x0, read[1] * s - content.y0, true) else null) else |_| null,
            .layer => machine.layer(position, .{ .context = &content, .function = sampleDip }) catch null,
        };
        const color = result orelse {
            space.stats.faulted_pixels += 1;
            continue;
        };
        if (!finite(color)) {
            space.stats.faulted_pixels += 1;
            continue;
        }
        // Source-over the backdrop, then blend by shape and clip coverage.
        const a = std.math.clamp(color[3], 0, 1);
        var mixed: [4]f32 = undefined;
        for (0..4) |i| {
            const over = std.math.clamp(color[i], 0, 1) + beneath[i] * (1 - a);
            mixed[i] = beneath[i] + (over - beneath[i]) * amount;
        }
        if (!transparent) mixed[3] = 1;
        surface.pixels[at] = fromColor(mixed);
    };
    return plan.dirty();
}

fn testProgram(source: []const u8) !*shader.Program {
    var diagnostic: shader.Diagnostic = .{};
    return shader.compile(std.testing.allocator, source, .{}, &diagnostic);
}
fn testEntry(program: *const shader.Program, values: shader.Values, box: Rect, margin: f32) !Entry {
    return .{ .program = program, .values = values, .target = .element, .box = box, .margin = margin };
}

test "color effects rewrite every captured pixel and fault to transparent" {
    const program = try testProgram(
        \\uniform float limit;
        \\vec4 color(vec2 position, vec4 pixel) {
        \\    if (position.x > limit) return vec4(1.0 / (position.x - position.x));
        \\    return vec4(pixel.a, 0.0, 0.0, pixel.a);
        \\}
    );
    defer program.destroy();
    var values = shader.Values.init(program);
    try values.set(program.uniform("limit").?, @as(f32, 3));
    // A 4x2 box at (10, 10) with a one-pixel halo: a 6x4 plane.
    const entry = try testEntry(program, values, .{ .x = 10, .y = 10, .width = 4, .height = 2 }, 0);
    const kernel = try carrier(entry.scale);
    const capture = try gaussian_scope.Capture.init(entry.captureRect(), &kernel);
    var source: [24]u32 = @splat(0xff0000ff);
    var scratch: [24]u32 = undefined;
    const workspace = try Workspace.create(std.testing.allocator, .{});
    defer workspace.destroy();
    applyElement(&entry, .{ .pixels = &source, .width = 6, .height = 4, .stride = 6 }, .{ .pixels = &scratch, .width = 6, .height = 4, .stride = 6 }, capture, workspace);
    // Plane column n sits at box-relative x = n - 0.5, halo included.
    try std.testing.expectEqual(@as(u32, 0xffff0000), source[6 + 1]);
    // Columns 4 and 5 divide by zero: non-finite, transparent pixels.
    try std.testing.expectEqual(@as(u32, 0), source[6 + 5]);
    try std.testing.expectEqual(@as(u64, 8), workspace.stats.faulted_pixels);
    try std.testing.expectEqual(@as(u64, 1), workspace.stats.applied);
    try std.testing.expectEqual(@as(u64, 24), workspace.stats.pixels);
}

test "distortion reads displaced content and transparency beyond the capture" {
    const program = try testProgram(
        \\vec2 distort(vec2 position) { return position + vec2(1.0, 0.0); }
    );
    defer program.destroy();
    const entry = try testEntry(program, shader.Values.init(program), .{ .x = 0, .y = 0, .width = 4, .height = 1 }, 0);
    const kernel = try carrier(entry.scale);
    const capture = try gaussian_scope.Capture.init(entry.captureRect(), &kernel);
    // Plane columns 0..5 hold distinct reds; the last reads past the edge.
    var source: [18]u32 = undefined;
    for (0..3) |row| for (0..6) |col| {
        source[row * 6 + col] = 0xff000000 | (@as(u32, @intCast(col * 40)) << 16);
    };
    var scratch: [18]u32 = undefined;
    const workspace = try Workspace.create(std.testing.allocator, .{});
    defer workspace.destroy();
    applyElement(&entry, .{ .pixels = &source, .width = 6, .height = 3, .stride = 6 }, .{ .pixels = &scratch, .width = 6, .height = 3, .stride = 6 }, capture, workspace);
    try std.testing.expectEqual(@as(u32, 0xff000000 | (80 << 16)), source[6 + 1]);
    try std.testing.expectEqual(@as(u32, 0), source[6 + 5]);
}

test "a layer effect blurs its content into the margin and respects the frame budget" {
    const program = try testProgram(
        \\vec4 layer(vec2 position) {
        \\    return (sample(position - vec2(1.0, 0.0)) + sample(position) + sample(position + vec2(1.0, 0.0))) / 3.0;
        \\}
    );
    defer program.destroy();
    const entry = try testEntry(program, shader.Values.init(program), .{ .x = 2, .y = 0, .width = 2, .height = 1 }, 2);
    const kernel = try carrier(entry.scale);
    const capture = try gaussian_scope.Capture.init(entry.captureRect(), &kernel);
    try std.testing.expectEqual(@as(u32, 8), capture.pixelWidth());
    var source: [8 * 7]u32 = @splat(0);
    // The box itself is opaque white; the margin is empty.
    for (3..5) |col| source[3 * 8 + col] = 0xffffffff;
    var scratch: [8 * 7]u32 = undefined;
    const workspace = try Workspace.create(std.testing.allocator, .{ .max_work = 8 * 7 * (program.max_steps + program.prologue_steps) });
    defer workspace.destroy();
    applyElement(&entry, .{ .pixels = &source, .width = 8, .height = 7, .stride = 8 }, .{ .pixels = &scratch, .width = 8, .height = 7, .stride = 8 }, capture, workspace);
    // The blur reaches one pixel into the margin.
    try std.testing.expectEqual(@as(u32, 0x55555555), source[3 * 8 + 2]);
    try std.testing.expectEqual(@as(u32, 0xaaaaaaaa), source[3 * 8 + 3]);
    // The budget allowed exactly one application.
    var again: [8 * 7]u32 = @splat(0xff00ff00);
    applyElement(&entry, .{ .pixels = &again, .width = 8, .height = 7, .stride = 8 }, .{ .pixels = &scratch, .width = 8, .height = 7, .stride = 8 }, capture, workspace);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), again[3 * 8 + 3]);
    try std.testing.expectEqual(@as(u64, 1), workspace.stats.skipped);
    workspace.beginFrame();
    applyElement(&entry, .{ .pixels = &again, .width = 8, .height = 7, .stride = 8 }, .{ .pixels = &scratch, .width = 8, .height = 7, .stride = 8 }, capture, workspace);
    try std.testing.expectEqual(@as(u64, 2), workspace.stats.applied);
}

test "backdrop shaders rewrite only their rounded shape inside the clip" {
    const program = try testProgram(
        \\vec4 color(vec2 position, vec4 pixel) { return vec4(1.0) - vec4(pixel.rgb, 0.0); }
    );
    defer program.destroy();
    var pixels: [16 * 8]u32 = @splat(0xff000000);
    const surface: cpu.Surface = .{ .pixels = &pixels, .width = 16, .height = 8, .stride = 16, .scale = 1, .clip = .{ 0, 0, 12, 8 } };
    var entry = try testEntry(program, shader.Values.init(program), .{ .x = 2, .y = 2, .width = 12, .height = 4 }, 0);
    entry.target = .backdrop;
    const workspace = try Workspace.create(std.testing.allocator, .{});
    defer workspace.destroy();
    var scratch: [16 * 8]u32 = undefined;
    const dirty = applyBackdrop(surface, false, &entry, &scratch, workspace);
    try std.testing.expectEqual(Dirty{ .left = 2, .top = 2, .right = 12, .bottom = 6 }, dirty);
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[3 * 16 + 4]);
    // Outside the shape and beyond the clip nothing changes.
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[1 * 16 + 4]);
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[3 * 16 + 12]);
    // Without scratch room the backdrop is left alone.
    @memset(&pixels, 0xff000000);
    _ = applyBackdrop(surface, false, &entry, scratch[0..4], workspace);
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[3 * 16 + 4]);
    try std.testing.expectEqual(@as(u64, 1), workspace.stats.skipped);
}
