const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const drawing = @import("ziggurat_drawing_resources");
const reservations = @import("gpu_reservations.zig");
const enabled = builtin.os.tag == .windows and @import("ziggurat_ui_options").gpu;

pub const Driver = enum { hardware, warp };
pub const capacity = 32;
pub const Options = struct {
    driver: Driver = .hardware,
    /// Logical BGRA texels, including a complete unpublished upload candidate.
    texture_bytes: usize = 32 * 1024 * 1024,
    /// Fixed domain/native metadata + all Texture shells + texture_bytes.
    total_bytes: usize = 64 * 1024 * 1024,
};
pub const Stats = struct {
    identity: u64,
    generation: u64,
    status: enum { ready, lost, stopped, exhausted },
    textures: usize,
    attachments: usize,
    pixel_bytes: usize,
    peak_reserved_bytes: usize,
    metadata_reservation: usize,
    workspace_reservation: usize,
    raster_reservation: usize,
    total_reservation: usize,
    peak_total_reservation: usize,
    uploads: u64,
    native_objects: u32,
    device_creations: u32,
    device_losses: u32,
    bitmap_creations: u64,
};
const NativeStats = extern struct { objects: u32 = 0, devices: u32 = 0, losses: u32 = 0, reserved: u32 = 0, bitmaps: u64 = 0 };
extern fn zgpu_domain_size() usize;
extern fn zgpu_domain_create(*drawing.GpuDomainEpoch, c_int, *anyopaque, *const fn (*anyopaque, c_int) callconv(.c) void, *i32) ?*anyopaque;
extern fn zgpu_domain_destroy(*anyopaque) void;
extern fn zgpu_domain_stop(*anyopaque) void;
extern fn zgpu_domain_recreate(*anyopaque) i32;
extern fn zgpu_domain_upload(*anyopaque, u32, u64, [*]const drawing.ImageLevel, u32, u32, *i32) ?*const drawing.GpuTextureToken;
extern fn zgpu_domain_release_texture(*anyopaque, u32) void;
extern fn zgpu_domain_stats(*anyopaque, *NativeStats) void;
extern fn zgpu_domain_inject_loss(*anyopaque) void;
extern fn zgpu_snapshot_offscreen(*anyopaque, *anyopaque, u32, u64, u32, u32, u32, *i32) ?*const drawing.GpuTextureToken;

/// Stable main-thread owner of one explicit D3D11/D2D resource domain.
/// No Context creates one implicitly. Close every Texture and renderer borrow
/// before close; stop revokes native payloads but preserves their stable shells.
pub const DeviceDomain = opaque {
    pub fn create(app: *z.App, allocator: std.mem.Allocator, options: Options) !*DeviceDomain {
        if (app.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!enabled) return error.GpuNotEnabled;
        const scope = app.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (options.texture_bytes == 0 or options.texture_bytes > drawing.max_image_budget or options.total_bytes > 512 * 1024 * 1024) return error.InvalidLimits;
        const metadata = @sizeOf(State) + zgpu_domain_size() + capacity * @sizeOf(TextureState);
        const budget = try reservations.Ledger.init(options.texture_bytes, options.total_bytes, metadata);
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        try checkApp(app);
        state.* = .{ .allocator = allocator, .owner = app.owner, .app = app, .options = options, .budget = budget, .epoch = .{ .identity = try drawing.reserveRasterIdentity() }, .stop = .{ .context = state, .stop = stop } };
        state.native = zgpu_domain_create(&state.epoch, if (options.driver == .warp) 1 else 0, state, beforeNativeRelease, &state.last_hresult) orelse {
            try result(state, state.last_hresult);
            return error.GraphicsInitializationFailed;
        };
        errdefer zgpu_domain_destroy(state.native.?);
        try checkApp(app);
        state.stop_token = try app.registerStop(&state.stop);
        return @ptrCast(state);
    }
    /// Copies immutable source pixels into a new owning GPU texture. Source
    /// descriptors/pixels need remain valid only until this explicit call ends.
    pub fn upload(self: *DeviceDomain, source: drawing.ImageView) !*Texture {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.busy = false;
        try ready(state);
        try source.validate();
        var slot: usize = 0;
        while (slot < capacity and state.textures[slot] != null) : (slot += 1) {}
        if (slot == capacity) return error.Full;
        var bytes: usize = 0;
        for (source.levels) |level| bytes += @as(usize, level.width) * level.height * 4;
        try state.budget.reserveTexture(bytes);
        errdefer if (state.epoch.status == 1) state.budget.releaseTexture(bytes);
        try source.lease.acquire();
        defer source.lease.release();
        const texture = try state.allocator.create(TextureState);
        errdefer state.allocator.destroy(texture);
        try checkApp(state.app.?);
        const identity = try drawing.reserveRasterIdentity();
        const fault = state.upload_fault;
        state.upload_fault = 0;
        const token = zgpu_domain_upload(state.native.?, @intCast(slot), identity, source.levels.ptr, @intCast(source.levels.len), fault, &state.last_hresult) orelse {
            try result(state, state.last_hresult);
            return error.TextureUploadFailed;
        };
        errdefer zgpu_domain_release_texture(state.native.?, @intCast(slot));
        try checkApp(state.app.?);
        texture.* = .{ .domain = state, .lease = drawing.Lease.init(state.owner), .slot = @intCast(slot), .token = token, .identity = identity, .generation = state.epoch.generation, .bytes = bytes, .charged = true };
        state.textures[slot] = texture;
        state.texture_count += 1;
        state.uploads += 1;
        return @ptrCast(texture);
    }
    pub fn recreate(self: *DeviceDomain) !void {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.busy = false;
        if (state.active_renderers != 0) return error.Busy;
        if (state.epoch.status == 1) return;
        if (state.epoch.status == 4) return error.GenerationExhausted;
        try result(state, zgpu_domain_recreate(state.native.?));
        try checkApp(state.app.?);
    }
    pub fn stats(self: *const DeviceDomain) !Stats {
        const state = cast(@constCast(self));
        try state.checkOwner();
        if (state.busy or state.release_depth != 0 or state.active_renderers != 0) return error.Busy;
        if (state.closing) return error.Closed;
        var native: NativeStats = .{};
        zgpu_domain_stats(state.native.?, &native);
        return .{ .identity = state.epoch.identity, .generation = state.epoch.generation, .status = switch (state.epoch.status) {
            1 => .ready,
            2 => .lost,
            4 => .exhausted,
            else => .stopped,
        }, .textures = state.texture_count, .attachments = state.attachment_count, .pixel_bytes = state.budget.texture_bytes, .peak_reserved_bytes = state.budget.peak_pixels, .metadata_reservation = state.budget.base_metadata + state.budget.surface_metadata, .workspace_reservation = state.budget.workspace_bytes, .raster_reservation = 2 * state.budget.raster_limit, .total_reservation = state.budget.totalReserved(), .peak_total_reservation = state.budget.peak_total, .uploads = state.uploads, .native_objects = native.objects, .device_creations = native.devices, .device_losses = native.losses, .bitmap_creations = native.bitmaps };
    }
    pub fn checkApplication(self: *DeviceDomain, app: *z.App) !void {
        const state = cast(self);
        try state.checkOwner();
        if (state.busy or state.release_depth != 0) return error.Busy;
        if (state.app != app) return error.DomainApplicationMismatch;
        try ready(state);
    }
    pub fn driver(self: *const DeviceDomain) !Driver {
        const state = cast(@constCast(self));
        try state.checkOwner();
        if (state.closing) return error.Closed;
        return state.options.driver;
    }
    pub fn close(self: *DeviceDomain) !void {
        const state = cast(self);
        try state.checkOwner();
        if (state.busy or state.release_depth != 0) return error.Busy;
        if (state.closing) return error.Closed;
        if (state.texture_count != 0 or state.attachment_count != 0 or state.active_renderers != 0) return error.ResourceInUse;
        const scope = if (state.app) |app| app.beginTeardownCallback() else null;
        defer if (scope) |value| value.end();
        state.busy = true;
        errdefer state.busy = false;
        if (state.stop_token) |token| _ = try state.app.?.cancelStop(token);
        state.closing = true;
        state.stop_token = null;
        zgpu_domain_destroy(state.native.?);
        state.native = null;
        state.app = null;
        state.allocator.destroy(state);
    }
    pub fn injectUploadFailureAtForTest(self: *DeviceDomain, one_based_level: u32) !void {
        const state = cast(self);
        try state.checkOwner();
        if (state.busy or state.release_depth != 0) return error.Busy;
        try ready(state);
        state.upload_fault = one_based_level;
    }
    pub fn injectDeviceLossForTest(self: *DeviceDomain) !void {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.busy = false;
        try ready(state);
        zgpu_domain_inject_loss(state.native.?);
    }

    // Renderer integration is explicit and bounded. The optional wait slot must
    // stay stable through releaseRenderer; the domain revokes it before native
    // loss/stop can close the borrowed DXGI handle. No application callbacks run.
    pub const Borrow = struct { native: *anyopaque, slot: u8, epoch: *const drawing.GpuDomainEpoch };
    pub fn acquireRenderer(self: *DeviceDomain, wait_slot: ?*?z.NativeWaitToken) !Borrow {
        const state = cast(self);
        const scope = try state.enter();
        defer scope.end();
        defer state.busy = false;
        try ready(state);
        var slot: usize = 0;
        while (slot < capacity and state.attachments[slot].used) : (slot += 1) {}
        if (slot == capacity) return error.Full;
        if (wait_slot) |pointer| if (pointer.* != null) return error.NativeWaitInUse;
        state.attachments[slot] = .{ .used = true, .wait_slot = wait_slot };
        state.attachment_count += 1;
        return .{ .native = state.native.?, .slot = @intCast(slot), .epoch = &state.epoch };
    }
    pub fn clearRendererWait(self: *DeviceDomain, slot: u8) void {
        const state = cast(self);
        std.debug.assert(state.owner == std.Thread.getCurrentId() and state.attachments[slot].used);
        clearWait(state, &state.attachments[slot]);
    }
    pub fn releaseRenderer(self: *DeviceDomain, slot: u8) void {
        const state = cast(self);
        std.debug.assert(state.owner == std.Thread.getCurrentId() and state.attachments[slot].used);
        self.clearRendererWait(slot);
        const attachment = &state.attachments[slot];
        state.budget.releaseSurface(attachment.planes, attachment.metadata, attachment.raster_limit);
        state.attachments[slot] = .{};
        state.attachment_count -= 1;
    }
    pub fn beginRenderer(self: *DeviceDomain) !z.AppCallbackScope {
        const state = cast(self);
        try state.checkOwner();
        if (state.busy or state.release_depth != 0) return error.Busy;
        try ready(state);
        const scope = state.app.?.beginCallback() orelse return error.Closed;
        state.active_renderers += 1;
        return scope;
    }
    /// Renderer-owned native cleanup remains legal after application stop.
    /// The stable attachment keeps this domain alive until releaseRenderer.
    pub fn beginRendererCleanup(self: *DeviceDomain) !?z.AppCallbackScope {
        const state = cast(self);
        try state.checkOwner();
        if (state.busy or state.release_depth != 0) return error.Busy;
        if (state.closing) return error.Closed;
        const scope = if (state.app) |app| app.beginTeardownCallback() else null;
        state.active_renderers += 1;
        return scope;
    }
    pub fn endRenderer(self: *DeviceDomain) void {
        const state = cast(self);
        std.debug.assert(state.owner == std.Thread.getCurrentId() and state.active_renderers != 0);
        state.active_renderers -= 1;
    }
    pub fn checkRendererReady(self: *DeviceDomain) !void {
        const state = cast(self);
        try state.checkOwner();
        if (state.busy or state.release_depth != 0) return error.Busy;
        try ready(state);
    }
    pub fn checkRendererOwner(self: *const DeviceDomain) !void {
        try cast(@constCast(self)).checkOwner();
    }
    pub fn validateRendererBorrow(self: *DeviceDomain, borrow: Borrow) !void {
        const state = cast(self);
        try self.checkRendererReady();
        if (borrow.epoch != &state.epoch or borrow.native != state.native or borrow.slot >= capacity or !state.attachments[borrow.slot].used) return error.InvalidRendererBorrow;
    }
    /// Internal surface reservation, released by the same linear renderer
    /// attachment. It precedes every surface allocator/native allocation.
    pub fn reserveSurface(self: *DeviceDomain, borrow: Borrow, planes: usize, metadata: usize, raster_limit: usize) !void {
        try self.validateRendererBorrow(borrow);
        const state = cast(self);
        const attachment = &state.attachments[borrow.slot];
        if (attachment.metadata != 0) return error.SurfaceAlreadyReserved;
        if (planes == 0 or metadata == 0 or raster_limit > drawing.max_image_budget) return error.InvalidLimits;
        try state.budget.reserveSurface(planes, metadata, raster_limit);
        attachment.planes = planes;
        attachment.metadata = metadata;
        attachment.raster_limit = raster_limit;
    }
    /// Optional renderer resources reserve their known owner storage before
    /// native creation. Old and unpublished candidates are charged together.
    pub fn reserveRendererMetadata(self: *DeviceDomain, borrow: Borrow, bytes: usize) !void {
        try self.validateRendererBorrow(borrow);
        const state = cast(self);
        const attachment = &state.attachments[borrow.slot];
        const metadata = try std.math.add(usize, attachment.metadata, bytes);
        try state.budget.reserveSurface(0, bytes, 0);
        attachment.metadata = metadata;
    }
    /// Cleanup is legal after loss/stop. The attachment physically owns both
    /// the old resource and any unpublished candidate until this return.
    pub fn releaseRendererMetadata(self: *DeviceDomain, borrow: Borrow, bytes: usize) void {
        const state = cast(self);
        std.debug.assert(state.owner == std.Thread.getCurrentId());
        std.debug.assert(borrow.native == state.native and borrow.epoch == &state.epoch);
        const attachment = &state.attachments[borrow.slot];
        std.debug.assert(attachment.used and bytes <= attachment.metadata);
        attachment.metadata -= bytes;
        state.budget.releaseSurface(0, bytes, 0);
    }
    /// Copies a committed transparent GPU front into a new immutable slot.
    /// No source pixels or staging/fence operation enter this transaction.
    pub fn snapshotRenderer(self: *DeviceDomain, borrow: Borrow, native: *anyopaque, width: u32, height: u32, fault: u32) !*Texture {
        const state = cast(self);
        const scope = try state.enterScoped(true);
        defer scope.end();
        defer state.busy = false;
        try ready(state);
        if (borrow.epoch != &state.epoch or borrow.native != state.native or borrow.slot >= capacity or !state.attachments[borrow.slot].used or state.attachments[borrow.slot].metadata == 0) return error.InvalidRendererBorrow;
        if (width == 0 or height == 0 or width > 16384 or height > 16384 or @as(u64, width) * height > 16 * 1024 * 1024) return error.InvalidGeometry;
        var slot: usize = 0;
        while (slot < capacity and state.textures[slot] != null) : (slot += 1) {}
        if (slot == capacity) return error.Full;
        const bytes = @as(usize, width) * height * 4;
        try state.budget.reserveTexture(bytes);
        errdefer if (state.epoch.status == 1) state.budget.releaseTexture(bytes);
        const texture = try state.allocator.create(TextureState);
        errdefer state.allocator.destroy(texture);
        try checkApp(state.app.?);
        const identity = try drawing.reserveRasterIdentity();
        const token = zgpu_snapshot_offscreen(state.native.?, native, @intCast(slot), identity, width, height, fault, &state.last_hresult) orelse {
            try result(state, state.last_hresult);
            return error.TextureSnapshotFailed;
        };
        errdefer zgpu_domain_release_texture(state.native.?, @intCast(slot));
        try checkApp(state.app.?);
        if (token.width != width or token.height != height) return error.InvalidGeometry;
        texture.* = .{ .domain = state, .lease = drawing.Lease.init(state.owner), .slot = @intCast(slot), .token = token, .identity = identity, .generation = state.epoch.generation, .bytes = bytes, .charged = true };
        state.textures[slot] = texture;
        state.texture_count += 1;
        return @ptrCast(texture);
    }
};

pub const Texture = opaque {
    pub fn view(self: *const Texture) !drawing.TextureView {
        const state = textureCast(@constCast(self));
        try state.lease.checkOwner();
        if (state.closing) return error.Closed;
        const result_view: drawing.TextureView = .{ .lease = &state.lease, .domain = &state.domain.epoch, .token = state.token, .identity = state.identity, .generation = state.generation, .width = state.token.width, .height = state.token.height, .levels = state.token.levels };
        try result_view.validate();
        return result_view;
    }
    pub fn close(self: *Texture) !void {
        const texture = textureCast(self);
        try texture.lease.checkOwner();
        if (texture.closing) return error.Closed;
        const state = texture.domain;
        if (state.busy or state.release_depth != 0) return error.Busy;
        try texture.lease.ensureUnused();
        const scope = if (state.app) |app| app.beginTeardownCallback() else null;
        defer if (scope) |value| value.end();
        state.busy = true;
        defer state.busy = false;
        texture.closing = true;
        zgpu_domain_release_texture(state.native.?, texture.slot);
        state.textures[texture.slot] = null;
        state.texture_count -= 1;
        if (texture.charged) state.budget.releaseTexture(texture.bytes);
        // The domain stays busy through the shell's final allocator callback.
        // Its owner therefore cannot disappear while this teardown uses it.
        state.allocator.destroy(texture);
    }
};
const Attachment = struct { used: bool = false, wait_slot: ?*?z.NativeWaitToken = null, planes: usize = 0, metadata: usize = 0, raster_limit: usize = 0 };
const State = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    app: ?*z.App,
    options: Options,
    budget: reservations.Ledger,
    epoch: drawing.GpuDomainEpoch,
    native: ?*anyopaque = null,
    stop: z.StopParticipant,
    stop_token: ?z.StopToken = null,
    textures: [capacity]?*TextureState = @splat(null),
    attachments: [capacity]Attachment = @splat(.{}),
    texture_count: usize = 0,
    attachment_count: usize = 0,
    active_renderers: usize = 0,
    uploads: u64 = 0,
    upload_fault: u32 = 0,
    last_hresult: i32 = 0,
    busy: bool = false,
    release_depth: usize = 0,
    closing: bool = false,
    fn checkOwner(self: *const State) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
    }
    fn enter(self: *State) !z.AppCallbackScope {
        return self.enterScoped(false);
    }
    fn enterScoped(self: *State, renderer_owner: bool) !z.AppCallbackScope {
        try self.checkOwner();
        if (self.busy or self.release_depth != 0 or (!renderer_owner and self.active_renderers != 0)) return error.Busy;
        if (self.closing) return error.Closed;
        const app = self.app orelse return error.Closed;
        const scope = app.beginCallback() orelse return error.Closed;
        self.busy = true;
        return scope;
    }
};
const TextureState = struct {
    domain: *State,
    lease: drawing.Lease,
    slot: u8,
    token: *const drawing.GpuTextureToken,
    identity: u64,
    generation: u64,
    bytes: usize,
    charged: bool,
    closing: bool = false,
};
fn cast(value: *DeviceDomain) *State {
    return @ptrCast(@alignCast(value));
}
fn textureCast(value: *Texture) *TextureState {
    return @ptrCast(@alignCast(value));
}
fn checkApp(app: *z.App) !void {
    if (app.phase != .ready and app.phase != .running) return error.Closed;
}
fn ready(state: *const State) !void {
    if (state.closing or state.app == null) return error.Closed;
    try checkApp(state.app.?);
    switch (state.epoch.status) {
        1 => {},
        2 => return error.DomainDeviceLost,
        4 => return error.GenerationExhausted,
        else => return error.Closed,
    }
}
fn clearWait(state: *State, attachment: *Attachment) void {
    if (attachment.wait_slot) |slot| {
        const previous = slot.*;
        slot.* = null;
        if (previous) |token| {
            if (state.app) |app| _ = app.unwatchNative(token);
        }
    }
}
fn beforeNativeRelease(context: *anyopaque, entering: c_int) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context));
    std.debug.assert(state.owner == std.Thread.getCurrentId());
    if (entering == 0) {
        std.debug.assert(state.release_depth != 0);
        state.release_depth -= 1;
        return;
    }
    state.release_depth += 1;
    for (&state.attachments) |*attachment| if (attachment.used) clearWait(state, attachment);
    for (state.textures) |texture| {
        if (texture) |value| value.charged = false;
    }
    state.budget.texture_bytes = 0;
}
fn stop(context: *anyopaque) !void {
    const state: *State = @ptrCast(@alignCast(context));
    std.debug.assert(state.owner == std.Thread.getCurrentId() and !state.busy and state.active_renderers == 0);
    state.busy = true;
    defer state.busy = false;
    zgpu_domain_stop(state.native.?);
    state.app = null;
    state.stop_token = null;
}
fn result(state: *State, hr: i32) !void {
    state.last_hresult = hr;
    if (hr >= 0) return;
    return switch (@as(u32, @bitCast(hr))) {
        0x8007000e => error.OutOfMemory,
        0x887a0005, 0x887a0006, 0x887a0007, 0x887a0020, 0x8899000c => error.DeviceLost,
        else => error.GraphicsFailed,
    };
}
