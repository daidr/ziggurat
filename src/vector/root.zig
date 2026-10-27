const std = @import("std");
const zio = @import("ziggurat_io");
pub const drawing = @import("ziggurat_drawing_resources");
const raster = @import("raster.zig");
pub const geometry = @import("geometry.zig");
pub const Bounds = @import("bounds.zig").Bounds;

pub const Point = struct { x: f64 = 0, y: f64 = 0 };
pub const Command = union(enum) {
    move: Point,
    line: Point,
    quadratic: struct { control: Point, end: Point },
    cubic: struct { first: Point, second: Point, end: Point },
    arc: Arc,
    close,
};
pub const Arc = struct {
    radius: Point,
    rotation: f64 = 0,
    large: bool = false,
    sweep: bool = false,
    end: Point,
    /// Local forward traversal vectors, not unit vectors or positions.
    pub const Directions = struct { outgoing: Point, incoming: Point };
    inline fn validate(self: Arc) !void {
        try validPoint(self.radius);
        try validPoint(self.end);
        if (!std.math.isFinite(self.rotation) or @abs(self.rotation) > 1e9) return error.InvalidGeometry;
    }
    /// Pure, allocation-free endpoint limits from the shared analytic arc
    /// conversion. Equal endpoints omit the arc and return null; a zero
    /// radius with distinct endpoints has the straight line's directions.
    pub fn endpointDirections(self: Arc, start: Point) !?Directions {
        try validPoint(start);
        try self.validate();
        return @import("arc.zig").directions(start, self);
    }
};
pub const Transform = struct {
    xx: f64 = 1,
    yx: f64 = 0,
    xy: f64 = 0,
    yy: f64 = 1,
    x0: f64 = 0,
    y0: f64 = 0,
    pub fn apply(self: Transform, point: Point) Point {
        return .{ .x = self.xx * point.x + self.xy * point.y + self.x0, .y = self.yx * point.x + self.yy * point.y + self.y0 };
    }
    /// Apply self first, then outer. Stroke geometry transforms with the path.
    pub fn then(self: Transform, outer: Transform) Transform {
        return .{
            .xx = outer.xx * self.xx + outer.xy * self.yx,
            .xy = outer.xx * self.xy + outer.xy * self.yy,
            .yx = outer.yx * self.xx + outer.yy * self.yx,
            .yy = outer.yx * self.xy + outer.yy * self.yy,
            .x0 = outer.xx * self.x0 + outer.xy * self.y0 + outer.x0,
            .y0 = outer.yx * self.x0 + outer.yy * self.y0 + outer.y0,
        };
    }
    pub fn validate(self: Transform) !void {
        inline for (zio.fields(Transform)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or @abs(value) > 1e6) return error.InvalidTransform;
        }
    }
};
pub const FillRule = enum { nonzero, even_odd };
pub const Cap = enum { butt, square, round };
pub const Join = enum { miter, bevel, round };
/// Fractions of each flattened subpath's local length. A reversed range keeps
/// the suffix and prefix; equal endpoints keep nothing. Dashes keep their
/// original phase when a range is trimmed.
pub const Trim = struct { start: f64 = 0, end: f64 = 1 };
/// Local strokes transform their outline with the path. Transformed strokes
/// measure width, dashes and trim on the transformed centerline before scale.
pub const StrokeSpace = enum { local, transformed };
pub const Stroke = struct {
    width: f64 = 1,
    cap: Cap = .butt,
    join: Join = .miter,
    miter_limit: f64 = 4,
    /// Borrowed only for prepare; an odd-length pattern repeats twice.
    dashes: []const f64 = &.{},
    dash_offset: f64 = 0,
    trim: Trim = .{},
    space: StrokeSpace = .local,
    pub fn validate(self: Stroke) !void {
        if (!std.math.isFinite(self.width) or self.width <= 0 or self.width > 1e6 or !std.math.isFinite(self.miter_limit) or self.miter_limit < 1 or self.miter_limit > 1e4) return error.InvalidStroke;
        if (self.dashes.len > 32 or !std.math.isFinite(self.dash_offset) or @abs(self.dash_offset) > 1e12) return error.InvalidDash;
        for (self.dashes) |value| if (!std.math.isFinite(value) or value < 0 or value > 1e9) return error.InvalidDash;
        if (!std.math.isFinite(self.trim.start) or !std.math.isFinite(self.trim.end) or self.trim.start < 0 or self.trim.start > 1 or self.trim.end < 0 or self.trim.end > 1) return error.InvalidTrim;
    }
    pub fn hasCuts(self: Stroke) bool {
        return self.dashes.len != 0 or self.trim.start != 0 or self.trim.end != 1;
    }
};
pub const Style = union(enum) { fill: FillRule, stroke: Stroke };
pub const Limits = struct {
    commands: usize = 4096,
    bytes: usize = 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.commands == 0 or self.commands > 65536 or self.bytes == 0 or self.bytes > 16 * 1024 * 1024) return error.InvalidLimits;
    }
};
pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
    pub fn request(self: *Cancellation) void {
        self.requested.store(true, .release);
    }
    pub fn check(self: *const Cancellation) !void {
        if (self.requested.load(.acquire)) return error.Cancelled;
    }
};
pub const PrepareLimits = struct {
    vertices: usize = 65536,
    edges: usize = 262144,
    /// Includes degenerate and horizontal edges discarded by scan conversion.
    edge_attempts: u64 = 1024 * 1024,
    /// Dash transitions, subpath length scans and cut segment traversal.
    stroke_steps: u64 = 1024 * 1024,
    bytes: usize = 64 * 1024 * 1024,
    scan_tests: u64 = 128 * 1024 * 1024,
    pub fn validate(self: PrepareLimits) !void {
        if (self.vertices == 0 or self.vertices > 262144 or self.edges == 0 or self.edges > 1048576 or self.edge_attempts == 0 or self.edge_attempts > 8 * 1024 * 1024 or self.stroke_steps == 0 or self.stroke_steps > 8 * 1024 * 1024 or self.bytes == 0 or self.bytes > 128 * 1024 * 1024 or self.scan_tests == 0 or self.scan_tests > 512 * 1024 * 1024) return error.InvalidLimits;
    }
};
pub const PrepareOptions = struct {
    /// Target owner after an explicit exclusive handoff. No thread is created.
    main_thread: std.Thread.Id,
    viewport: drawing.Rect,
    scale: f32 = 1,
    transform: Transform = .{},
    /// Captured by value before the first allocator callback. With a
    /// transformed stroke, maps its host outline to output coordinates
    /// before physical scale. Other styles reject this option.
    stroke_output: ?*const Transform = null,
    style: Style = .{ .fill = .nonzero },
    /// Maximum transformed curve deviation in physical pixels, before 4x4 AA.
    tolerance: f64 = 0.125,
    limits: PrepareLimits = .{},
    cancellation: ?*const Cancellation = null,
    /// Retain the 4x4 sample bits for geometric union/intersection during
    /// explicit preparation. Adds two bytes per aligned output pixel.
    retain_samples: bool = false,
    pub fn check(self: PrepareOptions) !void {
        if (self.cancellation) |cancel| try cancel.check();
    }
};
pub const ParseOptions = struct { input_bytes: usize = 1024 * 1024, limits: Limits = .{}, cancellation: ?*const Cancellation = null };
pub const Stats = struct {
    commands: usize,
    vertices: usize,
    edges: usize,
    edge_attempts: u64,
    stroke_steps: u64,
    owned_bytes: usize,
    prepare_peak_bytes: usize,
    scan_tests: u64,
};

/// Immutable owning command sequence. Create/prepare/close on the same owner.
/// Prepared coverage is independent and can outlive the source path.
pub const Path = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    commands: []Command,
    /// Strict SVG path-data grammar. This parses the d attribute, not XML.
    /// No file access, external resources or CSS is performed.
    pub fn parseData(allocator: std.mem.Allocator, bytes: []const u8, options: ParseOptions) !*Path {
        try options.limits.validate();
        if (options.input_bytes == 0 or options.input_bytes > 16 * 1024 * 1024) return error.InvalidLimits;
        if (bytes.len > options.input_bytes) return error.CapacityExceeded;
        const parser = @import("parser.zig");
        const count = try parser.parse(bytes, null, options);
        if (@sizeOf(Path) > options.limits.bytes or count > (options.limits.bytes -| @sizeOf(Path)) / @sizeOf(Command)) return error.CapacityExceeded;
        const path = try allocator.create(Path);
        errdefer allocator.destroy(path);
        const commands = try allocator.alloc(Command, count);
        errdefer allocator.free(commands);
        _ = try parser.parse(bytes, commands, options);
        path.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .commands = commands };
        return path;
    }
    pub fn create(allocator: std.mem.Allocator, commands: []const Command, limits: Limits) !*Path {
        try limits.validate();
        if (commands.len > limits.commands or commands.len > (limits.bytes -| @sizeOf(Path)) / @sizeOf(Command)) return error.CapacityExceeded;
        var open = false;
        for (commands) |command| switch (command) {
            .move => |p| {
                try validPoint(p);
                open = true;
            },
            .line => |p| {
                if (!open) return error.MoveRequired;
                try validPoint(p);
            },
            .quadratic => |q| {
                if (!open) return error.MoveRequired;
                try validPoint(q.control);
                try validPoint(q.end);
            },
            .cubic => |q| {
                if (!open) return error.MoveRequired;
                try validPoint(q.first);
                try validPoint(q.second);
                try validPoint(q.end);
            },
            .arc => |a| {
                if (!open) return error.MoveRequired;
                try a.validate();
            },
            .close => {
                if (!open) return error.MoveRequired;
                open = false;
            },
        };
        if (@sizeOf(Path) > limits.bytes) return error.CapacityExceeded;
        const path = try allocator.create(Path);
        errdefer allocator.destroy(path);
        path.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .commands = try allocator.dupe(Command, commands) };
        return path;
    }
    pub fn checkOwner(self: *const Path) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
    }
    /// Analytic geometry bounds, excluding stroke, markers and isolated moves.
    /// Uses the same endpoint arc conversion as coverage preparation.
    pub fn bounds(self: *const Path, transform: Transform, cancellation: ?*const Cancellation) !?Bounds {
        try self.checkOwner();
        try transform.validate();
        return @import("bounds.zig").calculate(self.commands, transform, cancellation);
    }
    pub fn prepare(self: *const Path, allocator: std.mem.Allocator, options: PrepareOptions) !*Prepared {
        try self.checkOwner();
        const output_value: ?Transform = if (options.stroke_output) |output| output.* else null;
        var captured = options;
        captured.stroke_output = if (output_value) |*output| output else null;
        try captured.limits.validate();
        try captured.transform.validate();
        if (captured.stroke_output) |output| {
            if (captured.style != .stroke or captured.style.stroke.space != .transformed) return error.InvalidStrokeSpace;
            try output.validate();
        }
        if (!std.math.isFinite(captured.tolerance) or captured.tolerance < 0.015625 or captured.tolerance > 1) return error.InvalidTolerance;
        if (captured.style == .stroke) try captured.style.stroke.validate();
        return raster.prepare(self, allocator, captured);
    }
    pub fn close(self: *Path) !void {
        try self.checkOwner();
        const allocator = self.allocator;
        allocator.free(self.commands);
        allocator.destroy(self);
    }
};
pub fn validPoint(point: Point) !void {
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y) or @abs(point.x) > 1e9 or @abs(point.y) > 1e9) return error.InvalidGeometry;
}

/// Stable A8 snapshot. Do not free while a frame or renderer holds its Lease.
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    lease: drawing.Lease,
    main_thread: std.Thread.Id,
    adopted: bool,
    identity: u64,
    coverage: drawing.Coverage,
    samples: []const u16 = &.{},
    metrics: Stats,
    pub fn adopt(self: *Prepared) !void {
        if (std.Thread.getCurrentId() != self.main_thread) return error.WrongThread;
        if (self.adopted) return error.AlreadyAdopted;
        if (self.lease.pins != 0) return error.ResourceInUse;
        self.lease.owner = self.main_thread;
        self.adopted = true;
    }
    pub fn view(self: *Prepared) !drawing.CoverageView {
        try self.lease.checkOwner();
        if (!self.adopted) return error.NotAdopted;
        return .{ .lease = &self.lease, .identity = self.identity, .coverage = self.coverage };
    }
    pub fn stats(self: *const Prepared) !Stats {
        try self.lease.checkOwner();
        return self.metrics;
    }
    pub fn close(self: *Prepared) !void {
        try self.lease.ensureUnused();
        const allocator = self.allocator;
        allocator.free(self.coverage.pixels);
        allocator.free(self.samples);
        allocator.destroy(self);
    }
};

test {
    _ = @import("tests.zig");
    _ = @import("geometry_test.zig");
    _ = @import("stroke_space_test.zig");
}
