const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const drawing = @import("ziggurat_drawing_resources");
const commands = @import("commands.zig");
const geometry = @import("geometry.zig");
const layout = @import("layout.zig");
const layers = @import("layers.zig");
const gaussian_scope = @import("gaussian_scope.zig");
const Software = if (builtin.os.tag == .windows) @import("windows.zig").Renderer else @import("linux.zig").Renderer;

pub const Options = struct {
    size: z.Size,
    max_depth: u8 = 2,
    legacy_text: layers.LegacyText = .grayscale,
    workspace_bytes: usize = 64 * 1024 * 1024,
    resident_bytes: usize = 8 * 1024 * 1024,
    /// Sum of every live Snapshot's pixels and metadata, including candidates.
    output_bytes: usize = 16 * 1024 * 1024,
    /// Workspace + metadata + twice the resident limit + full output limit.
    /// Native font/codec/graphics object internals and allocator headers are opaque.
    total_bytes: usize = 64 * 1024 * 1024,
    /// Conservative whole-plane visits, checked before output allocation.
    /// This is not a time bound for native text shaping or allocator calls.
    render_work: u64 = 128 * 1024 * 1024,
    transform_source: ?layout.Size = null,
};
pub const Stats = struct {
    size: z.Size,
    workspace_bytes: usize,
    metadata_bytes: usize,
    resident_limit: usize,
    resident_current: usize,
    resident_candidate_bound: usize,
    output_current: usize,
    output_peak: usize,
    reserved_peak: usize,
    renders: u64,
    last_render_work: u64,
    layers: layers.Stats,
};
pub const SnapshotStats = struct { size: z.Size, pixel_bytes: usize, owned_bytes: usize };

/// Fixed-size main-thread software renderer. A successful render creates an
/// independent immutable image; it does not retain the source command buffer.
/// The allocator context must outlive this Surface AND its last Snapshot.
pub const Surface = opaque {
    pub fn create(app: *z.App, allocator: std.mem.Allocator, options: Options) !*Surface {
        return createInternal(false, app, allocator, options, {}, 0);
    }
    /// Explicit filter preparation. Ordinary create never references this
    /// specialized path or the optional native filter factory.
    pub fn createGaussian(app: *z.App, allocator: std.mem.Allocator, options: Options, filter: gaussian_scope.FilterOptions) !*Surface {
        return createInternal(true, app, allocator, options, filter, 0);
    }
    pub fn createWithFailureForTest(app: *z.App, allocator: std.mem.Allocator, options: Options, one_based_plane: u32) !*Surface {
        return createInternal(false, app, allocator, options, {}, one_based_plane);
    }
    pub fn createGaussianWithFailureForTest(app: *z.App, allocator: std.mem.Allocator, options: Options, filter: gaussian_scope.FilterOptions, one_based_plane: u32) !*Surface {
        return createInternal(true, app, allocator, options, filter, one_based_plane);
    }
    fn createInternal(comptime filtered: bool, app: *z.App, allocator: std.mem.Allocator, options: Options, filter_options: if (filtered) gaussian_scope.FilterOptions else void, fault: u32) !*Surface {
        if (app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (builtin.cpu.arch.endian() != .little) return error.UnsupportedPixelEndian;
        const scope = app.beginCallback() orelse return error.Closed;
        defer scope.end();
        const filter: ?gaussian_scope.Plan = if (filtered) try filterPlan(options, filter_options) else null;
        const plan = try Plan.init(options, filter);
        const account = try allocator.create(Account);
        errdefer allocator.destroy(account);
        try checkApp(app);
        account.* = .{ .allocator = allocator, .owner = app.owner, .limit = options.output_bytes };
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .owner = app.owner, .app = app, .options = options, .filter_options = if (filtered) filter_options else null, .plan = plan, .account = account, .stop = .{ .context = state, .stop = stop } };
        errdefer state.renderer.deinit();
        if (options.transform_source != null) {
            state.transform_storage = try allocator.create(commands.TransformStorage);
            state.transform_storage.?.* = .{ .scale = options.size.scale };
        }
        errdefer if (state.transform_storage) |storage| allocator.destroy(storage);
        if (filtered) {
            state.filter_storage = try allocator.create(commands.FilterStorage);
            state.filter_storage.?.* = .{};
        }
        errdefer if (state.filter_storage) |storage| allocator.destroy(storage);
        try checkApp(app);
        try state.renderer.setImageBudget(options.resident_bytes);
        state.renderer.injectLayerPreparationFailureForTest(fault);
        if (filtered) state.renderer.commitLayerCandidate(try state.renderer.createGaussianCandidate(allocator, filter.?)) else if (options.transform_source) |source| try state.renderer.prepareTransforms(allocator, .{ .layers = plan.layer_options, .source_size = source, .render_work = @min(options.render_work, 512 * 1024 * 1024) }) else try state.renderer.prepareLayers(allocator, plan.layer_options);
        try state.renderer.prepareOffscreen();
        try checkApp(app);
        state.token = try app.registerStop(&state.stop);
        return @ptrCast(state);
    }

    /// Captures commands/text/resource descriptors and takes its own temporary
    /// pins before any allocation. Allocator callbacks may reset the source
    /// Buffer; they cannot close a pinned source or reenter this Surface.
    pub fn render(self: *Surface, source: *const commands.Buffer) !*Snapshot {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.busy = false;
        const work = try preflight(source, state.options, state.filter_options);
        defer state.captured.reset();
        if (source.transformResources().len != 0) try state.captured.bindTransformStorage(state.transform_storage orelse return error.TransformsRequired);
        if (source.filterResources().len != 0) try state.captured.bindFilterStorage(state.filter_storage orelse return error.GaussianNotPrepared);
        try capture(&state.captured, source);
        const cost = try add(state.plan.plane_bytes, @sizeOf(SnapshotState));
        try state.account.reserve(cost);
        errdefer state.account.release(cost);
        const snapshot = try state.allocator.create(SnapshotState);
        state.account.allocated(@sizeOf(SnapshotState));
        errdefer {
            state.allocator.destroy(snapshot);
            state.account.freed(@sizeOf(SnapshotState));
        }
        try checkApp(state.app.?);
        const pixels = try state.allocator.alloc(u8, state.plan.plane_bytes);
        state.account.allocated(pixels.len);
        errdefer {
            state.allocator.free(pixels);
            state.account.freed(pixels.len);
        }
        try checkApp(state.app.?);
        const identity = try drawing.reserveRasterIdentity();
        try state.renderer.beginOffscreen();
        errdefer state.renderer.abort();
        try state.renderer.replayBuffer(&state.captured);
        if (state.export_fault) {
            state.export_fault = false;
            return error.OffscreenExportFailed;
        }
        try state.renderer.endOffscreen(pixels);
        snapshot.* = .{ .allocator = state.allocator, .lease = drawing.Lease.init(state.owner), .account = state.account, .cost = cost, .pixels = pixels, .level = .{ .pixels = pixels.ptr, .byte_len = pixels.len, .width = state.options.size.width, .height = state.options.size.height, .stride = state.options.size.width * 4 }, .identity = identity, .size = state.options.size };
        state.renders +%= 1;
        state.last_render_work = work;
        return @ptrCast(snapshot);
    }

    pub fn uploadImage(self: *Surface, view: drawing.ImageView) !void {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.busy = false;
        try state.renderer.uploadImage(view);
    }
    pub fn uploadCoverage(self: *Surface, view: drawing.CoverageView) !void {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.busy = false;
        if (view.coverage.scale != state.options.size.scale) return error.CoverageDpiMismatch;
        try state.renderer.uploadCoverage(view);
    }
    pub fn releaseImage(self: *Surface, identity: u64) !bool {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.busy = false;
        return state.renderer.releaseImage(identity);
    }
    pub fn releaseCoverage(self: *Surface, identity: u64) !bool {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.busy = false;
        return state.renderer.releaseCoverage(identity);
    }
    pub fn injectExportFailureForTest(self: *Surface) !void {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.busy = false;
        state.export_fault = true;
    }
    pub fn stats(self: *const Surface) !Stats {
        const state = cast(@constCast(self));
        try state.checkOwner();
        if (state.busy) return error.Busy;
        if (state.closing) return error.Closed;
        if (state.account.cleanup_depth != 0) return error.Busy;
        return .{ .size = state.options.size, .workspace_bytes = if (state.app != null) state.plan.workspace_bytes else 0, .metadata_bytes = if (state.app != null) state.plan.metadata_bytes else @sizeOf(State) + @sizeOf(Account) + @as(usize, if (state.transform_storage != null) @sizeOf(commands.TransformStorage) else 0) + @as(usize, if (state.filter_storage != null) @sizeOf(commands.FilterStorage) else 0), .resident_limit = state.options.resident_bytes, .resident_current = state.renderer.rasterStats().pixel_bytes, .resident_candidate_bound = state.options.resident_bytes * 2, .output_current = state.account.current, .output_peak = state.account.peak, .reserved_peak = state.plan.reserved_peak, .renders = state.renders, .last_render_work = state.last_render_work, .layers = state.renderer.layerStats() };
    }
    pub fn close(self: *Surface) !void {
        const state = cast(self);
        try state.checkOwner();
        if (state.busy) return error.Busy;
        if (state.closing) return error.Closed;
        if (state.account.cleanup_depth != 0) return error.Busy;
        const scope: ?z.AppCallbackScope = if (state.app) |app| app.beginTeardownCallback() else null;
        defer if (scope) |value| value.end();
        state.busy = true;
        errdefer state.busy = false;
        if (state.token) |token| _ = try state.app.?.cancelStop(token);
        state.closing = true;
        state.app = null;
        state.token = null;
        state.renderer.deinit();
        state.captured.reset();
        if (state.transform_storage) |storage| {
            state.transform_storage = null;
            state.allocator.destroy(storage);
        }
        if (state.filter_storage) |storage| {
            state.filter_storage = null;
            state.allocator.destroy(storage);
        }
        const account = state.account;
        const allocator = state.allocator;
        account.surface_alive = false;
        account.releaseReference();
        allocator.destroy(state);
    }
};

/// Owning BGRA8 snapshot with one mip level. It survives Surface/App shutdown.
/// Access and final release remain on the process main thread. No handoff or
/// implicit PNG encoding is provided by this first offscreen resource API.
pub const Snapshot = opaque {
    pub fn view(self: *const Snapshot) !drawing.ImageView {
        const state = snapshotCast(@constCast(self));
        try state.lease.checkOwner();
        if (state.closing) return error.Closed;
        return .{ .lease = &state.lease, .identity = state.identity, .levels = @as([*]const drawing.ImageLevel, @ptrCast(&state.level))[0..1] };
    }
    pub fn stats(self: *const Snapshot) !SnapshotStats {
        const state = snapshotCast(@constCast(self));
        try state.lease.checkOwner();
        if (state.closing) return error.Closed;
        return .{ .size = state.size, .pixel_bytes = state.pixels.len, .owned_bytes = state.cost };
    }
    pub fn close(self: *Snapshot) !void {
        const state = snapshotCast(self);
        try state.lease.checkOwner();
        if (state.closing) return error.Closed;
        try state.lease.ensureUnused();
        const account = state.account;
        // Keep a closing shell inside the output budget until its allocator
        // callback returns. No new output may enter this account in that gap.
        // If the Surface is already gone there is no allocation entry left.
        const guarded = account.surface_alive;
        if (guarded) account.cleanup_depth += 1;
        state.closing = true;
        const pixels = state.pixels;
        state.pixels = &.{};
        state.level = undefined;
        const allocator = state.allocator;
        const cost = state.cost;
        // Revoke all readable storage before the first allocator callback;
        // keep the closed shell alive through pixel/account deallocation.
        allocator.free(pixels);
        account.freed(pixels.len);
        account.freed(@sizeOf(SnapshotState));
        account.release(cost);
        allocator.destroy(state);
        // The live Surface's reference cannot disappear while cleanup_depth
        // rejects close; App stop only releases native objects, not that shell.
        if (guarded) account.cleanup_depth -= 1;
    }
};

const Account = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    references: usize = 1,
    surface_alive: bool = true,
    cleanup_depth: usize = 0,
    limit: usize,
    current: usize = 0,
    live: usize = 0,
    peak: usize = 0,
    fn reserve(self: *Account, bytes: usize) !void {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
        if (bytes > self.limit -| self.current) return error.OutputBudgetExceeded;
        self.references = std.math.add(usize, self.references, 1) catch return error.CapacityExceeded;
        self.current += bytes;
    }
    fn allocated(self: *Account, bytes: usize) void {
        std.debug.assert(bytes <= self.current - self.live);
        self.live += bytes;
        self.peak = @max(self.peak, self.live);
    }
    fn freed(self: *Account, bytes: usize) void {
        std.debug.assert(bytes <= self.live);
        self.live -= bytes;
    }
    fn release(self: *Account, bytes: usize) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
        std.debug.assert(bytes <= self.current);
        self.current -= bytes;
        self.releaseReference();
    }
    fn releaseReference(self: *Account) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
        self.references -= 1;
        if (self.references == 0) {
            std.debug.assert(self.current == 0 and self.live == 0 and self.cleanup_depth == 0);
            self.allocator.destroy(self);
        }
    }
};
const SnapshotState = struct {
    allocator: std.mem.Allocator,
    lease: drawing.Lease,
    account: *Account,
    cost: usize,
    pixels: []u8,
    level: drawing.ImageLevel,
    identity: u64,
    size: z.Size,
    closing: bool = false,
};
const State = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    app: ?*z.App,
    token: ?z.StopToken = null,
    stop: z.StopParticipant,
    options: Options,
    plan: Plan,
    account: *Account,
    renderer: Software = .{},
    captured: commands.Buffer = .{},
    transform_storage: ?*commands.TransformStorage = null,
    filter_storage: ?*commands.FilterStorage = null,
    filter_options: ?gaussian_scope.FilterOptions = null,
    busy: bool = false,
    closing: bool = false,
    renders: u64 = 0,
    export_fault: bool = false,
    last_render_work: u64 = 0,
    fn checkOwner(self: *const State) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
    }
    fn enter(self: *State) !z.AppCallbackScope {
        try self.checkOwner();
        if (self.busy) return error.Busy;
        if (self.closing) return error.Closed;
        if (self.account.cleanup_depth != 0) return error.Busy;
        const app = self.app orelse return error.Closed;
        const scope = app.beginCallback() orelse return error.Closed;
        self.busy = true;
        return scope;
    }
};
const Plan = struct {
    layer_options: layers.Options,
    plane_bytes: usize,
    workspace_bytes: usize,
    metadata_bytes: usize,
    reserved_peak: usize,
    fn init(options: Options, filter: ?gaussian_scope.Plan) !Plan {
        if (options.total_bytes == 0 or options.total_bytes > layers.max_bytes or options.output_bytes == 0 or options.output_bytes > layers.max_bytes or options.resident_bytes == 0 or options.resident_bytes > drawing.max_image_bytes or options.render_work == 0 or options.render_work > 1024 * 1024 * 1024) return error.InvalidOffscreenLimits;
        if (options.transform_source != null and options.render_work > 512 * 1024 * 1024) return error.InvalidOffscreenLimits;
        if (options.size.width > 16384 or options.size.height > 16384 or @as(u64, options.size.width) * options.size.height > 16 * 1024 * 1024) return error.InvalidGeometry;
        const layer_options: layers.Options = .{ .size = options.size, .max_depth = options.max_depth, .legacy_text = options.legacy_text, .bytes = options.workspace_bytes, .total_bytes = options.total_bytes };
        const layer_plan = if (filter) |value| value.layers else if (options.transform_source) |source| try layers.Plan.initTransforms(.{ .layers = layer_options, .source_size = source, .render_work = @min(options.render_work, 512 * 1024 * 1024) }, if (builtin.os.tag == .windows) .gdi else .cairo) else try layers.Plan.init(layer_options, if (builtin.os.tag == .windows) .gdi else .cairo);
        const workspace_bytes = if (filter) |value| value.pixel_bytes else layer_plan.pixel_bytes;
        const metadata = try add(try add(try add(@sizeOf(State), @sizeOf(Account)), Software.layerMetadataBytes()), (if (options.transform_source != null) @as(usize, @sizeOf(commands.TransformStorage)) else 0) + (if (filter != null) @sizeOf(commands.FilterStorage) + Software.gaussianMetadataBytes() else 0));
        const reserve = try add(try add(try add(workspace_bytes, metadata), options.resident_bytes * 2), options.output_bytes);
        if (try add(layer_plan.plane_bytes, @sizeOf(SnapshotState)) > options.output_bytes) return error.OutputBudgetExceeded;
        if (reserve > options.total_bytes) return error.OffscreenBudgetExceeded;
        return .{ .layer_options = layer_options, .plane_bytes = layer_plan.plane_bytes, .workspace_bytes = workspace_bytes, .metadata_bytes = metadata, .reserved_peak = reserve };
    }
};
fn add(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.OffscreenBudgetExceeded;
}
fn checkApp(app: *const z.App) !void {
    if (app.phase == .stopping or app.phase == .stopped) return error.Closed;
}
fn cast(surface: *Surface) *State {
    return @ptrCast(@alignCast(surface));
}
fn snapshotCast(snapshot: *Snapshot) *SnapshotState {
    return @ptrCast(@alignCast(snapshot));
}
fn stop(context: *anyopaque) !void {
    const state: *State = @ptrCast(@alignCast(context));
    std.debug.assert(!state.busy);
    state.busy = true;
    defer state.busy = false;
    state.app = null;
    state.token = null;
    state.renderer.deinit();
    state.captured.reset();
}

fn preflight(buffer: *const commands.Buffer, options: Options, filter_options: ?gaussian_scope.FilterOptions) !u64 {
    const layer_options: layers.Options = .{ .size = options.size, .max_depth = options.max_depth, .legacy_text = options.legacy_text, .bytes = options.workspace_bytes, .total_bytes = options.total_bytes };
    const filter = if (filter_options) |value| try filterPlan(options, value) else null;
    const plan: ?layers.Plan = if (filter) |value| value.layers else if (options.transform_source) |source| try layers.Plan.initTransforms(.{ .layers = layer_options, .source_size = source, .render_work = @min(options.render_work, 512 * 1024 * 1024) }, if (builtin.os.tag == .windows) .gdi else .cairo) else null;
    return @import("render_batch.zig").preflight(buffer, .{ .size = options.size, .max_depth = options.max_depth, .legacy_text = options.legacy_text, .render_work = options.render_work, .transform_plan = plan, .gaussian_capacity = if (filter) |value| value.capacity else null });
}
fn filterPlan(options: Options, filter: gaussian_scope.FilterOptions) !gaussian_scope.Plan {
    const layer_options: layers.Options = .{ .size = options.size, .max_depth = options.max_depth, .legacy_text = options.legacy_text, .bytes = options.workspace_bytes, .total_bytes = options.total_bytes };
    const transforms: ?layers.TransformOptions = if (options.transform_source) |source| .{ .layers = layer_options, .source_size = source, .render_work = @min(options.render_work, 512 * 1024 * 1024) } else null;
    return try gaussian_scope.Plan.init(gaussian_scope.withLayers(filter, layer_options, @min(options.render_work, 512 * 1024 * 1024)), if (builtin.os.tag == .windows) .gdi else .cairo, transforms);
}
const capture = @import("render_batch.zig").capture;
