const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const e = @import("ziggurat_document_editor");
const ui = @import("ziggurat_ui");
const n = @import("native.zig");
const Budget = @import("budget.zig").Budget;
pub const model = @import("model.zig");
pub const auxiliary = @import("auxiliary.zig");
pub const AuxiliaryAction = struct { key: auxiliary.Key, operation: union(enum) { invoke, expanded: bool } };
pub const AuxiliaryHandler = struct {
    context: *anyopaque,
    validate: *const fn (*anyopaque, z.Window, u64, auxiliary.Key) anyerror!void,
    call: *const fn (*anyopaque, z.Window, AuxiliaryAction) anyerror!void,
    focus: ?*const fn (*anyopaque, z.Window, auxiliary.Key) anyerror!void = null,
};
pub const AcceptedAuxiliary = struct { key: auxiliary.Key, frame_id: u64, epoch: u64, enabled: bool, visible: bool, focused: bool, focusable: bool, expanded: bool };
pub const AuxiliaryOptions = struct { limits: auxiliary.Limits = .{}, handler: AuxiliaryHandler };
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};

pub const NativeStorage = if (builtin.os.tag == .linux) enum { glib } else enum { system_com };
pub const Options = struct {
    native_storage: NativeStorage = if (builtin.os.tag == .linux) .glib else .system_com,
    bytes: usize = 64 * 1024 * 1024,
    ranges: u32 = 1024,
    output_units: u32 = 2 * 1024 * 1024,
    cells: usize = 16384,
    carets: usize = 16384,
    lines: usize = 4096,
    /// Preallocate exact per-source affine/convex-clip publication storage.
    affine_geometry: bool = false,
    /// Require a successful front's nonzero epoch for queued owner actions.
    presentation_epochs: bool = false,
    /// Build full-document system ICU word units, including trailing breaks.
    /// Default queries keep their existing larger-unit fallback and storage.
    word_units: bool = false,
    /// Optional stable authority borrowed until detach/close. Only affine,
    /// presentation-stamped publishers may lend their accepted Frame stamp.
    publication: ?*e.PresentationLease = null,
    auxiliary: ?AuxiliaryOptions = null,
    text: model.Limits = .{},
};
pub const Changed = struct { context: *anyopaque, call: *const fn (*anyopaque, z.Window, usize, *e.Adapter) anyerror!void };
pub const Scroll = struct { context: *anyopaque, call: *const fn (*anyopaque, z.Window, usize, d.Range, bool) anyerror!void };
pub const Actions = struct {
    context: *anyopaque,
    validate: *const fn (*anyopaque, z.Window, usize, u64) anyerror!void,
    focus: ?*const fn (*anyopaque, z.Window, usize) anyerror!void = null,
    select: ?*const fn (*anyopaque, z.Window, usize, []const d.Selection, usize) anyerror!void = null,
    scroll: ?*const fn (*anyopaque, z.Window, usize, d.Range, bool) anyerror!void = null,
};
pub const GeometrySelection = union(enum) { all, paragraphs: []const usize, hidden };
/// Source identity and policies stay fixed until close. In a unified view the
/// ghost source is read-only, unselectable and unfocusable; B alone owns input.
pub const Source = struct {
    adapter: *e.Adapter,
    name: []const u8,
    read_only: bool = false,
    selectable: bool = true,
    focusable: bool = true,
    changed: ?Changed = null,
    scroll: ?Scroll = null,
    actions: ?Actions = null,
};
const SourceState = struct { options: Source, document: *d.Document, text: ?*n.Text = null, stamp: u64 = 0 };
const MappingState = struct {
    recorded: [2]ui.CoordinateMapping = undefined,
    native: [2]n.Mapping = undefined,
    reference: [2]ui.affine.Ref = undefined,
    mask: u2 = 0,
};
const AuxiliaryMapping = struct { recorded: ui.CoordinateMapping = undefined, native: n.Mapping = undefined };
const AuxiliaryState = struct {
    nodes: []ui.accessibility.Node,
    labels: []u8,
    geometry: []n.AuxGeometry,
    plan: []auxiliary.Node = &.{},
    plan_labels: []u8 = &.{},
    native: ?*n.AuxPlan = null,
    recorded: bool = false,
    affine: ?*AuxiliaryMapping = null,

    fn create(allocator: std.mem.Allocator, limits: auxiliary.Limits, affine: bool) !*AuxiliaryState {
        const self = try allocator.create(AuxiliaryState);
        errdefer allocator.destroy(self);
        const nodes = try allocator.alloc(ui.accessibility.Node, limits.nodes);
        errdefer allocator.free(nodes);
        const labels = try allocator.alloc(u8, limits.label_bytes);
        errdefer allocator.free(labels);
        const geometry = try allocator.alloc(n.AuxGeometry, limits.nodes);
        errdefer allocator.free(geometry);
        const mapping = if (affine) try allocator.create(AuxiliaryMapping) else null;
        if (mapping) |value| value.* = .{};
        self.* = .{ .nodes = nodes, .labels = labels, .geometry = geometry, .affine = mapping };
        return self;
    }
    fn close(self: *AuxiliaryState, allocator: std.mem.Allocator) void {
        if (builtin.os.tag == .windows) n.zda_auxiliary_release(self.native);
        allocator.free(self.plan);
        allocator.free(self.plan_labels);
        allocator.free(self.geometry);
        allocator.free(self.labels);
        allocator.free(self.nodes);
        if (self.affine) |value| allocator.destroy(value);
        allocator.destroy(self);
    }
};
pub const Stats = struct { requested_bytes: u64, peak_reserved_bytes: u64, byte_limit: usize, host_staging_bytes: u64, states: u32, providers: u32, ranges: u32, blobs: u32, text_builds: u64, geometry_builds: u64 };
pub const ResourceCounts = struct { accounts: u32, blocks: u32, bytes: u64 };
pub fn resourceCounts() ResourceCounts {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return .{ .accounts = 0, .blocks = 0, .bytes = 0 };
    var result: ResourceCounts = undefined;
    n.zda_ledger_counts(&result.accounts, &result.blocks, &result.bytes);
    return result;
}

const NativeCleanup = struct {
    node: z.Cleanup,
    native: *n.State,
    allocator: std.mem.Allocator,
    app: *z.App,
    id: z.diagnostics.WindowId,
    fn run(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const allocator = self.allocator;
        const app = self.app;
        const id = self.id;
        const hr = n.zda_native_disconnect(self.native);
        allocator.destroy(self);
        if (hr < 0) app.report(.{ .domain = .hresult, .operation = .resource_release, .window = id, .code = @bitCast(hr), .err = error.AccessibilityDisconnectFailed });
    }
};

/// Optional complete-document provider. Adapter and Document are the only
/// editable state. Native MTA readers retain native-only immutable snapshots.
/// App, Context (while installed), source Adapters and allocator cover its life.
pub const Bridge = struct {
    allocator: std.mem.Allocator,
    window: z.Window,
    options: Options,
    owner: std.Thread.Id,
    native: ?*n.State = null,
    cleanup: ?*NativeCleanup = null,
    budget: Budget = undefined,
    sources: [2]SourceState = undefined,
    count: usize,
    stop_node: z.StopParticipant = undefined,
    stop_token: ?z.StopToken = null,
    context_token: ?ui.AccessibilitySourceToken = null,
    busy: bool = false,
    detached: bool = false,
    pending: [2]?*n.Geometry = .{ null, null },
    pending_revision: [2]u64 = .{ 0, 0 },
    pending_projection: [2]u64 = .{ 0, 0 },
    pending_scale: [2]f32 = .{ 0, 0 },
    pending_bounds: [2]ui.Rect = @splat(.{ .x = 0, .y = 0, .width = 0, .height = 0 }),
    pending_hidden: [2]bool = .{ false, false },
    pending_epoch: u64 = 0,
    mapping: ?*MappingState = null,
    auxiliary_state: ?*AuxiliaryState = null,
    native_scale: f64 = 0,
    armed: bool = false,
    text_builds: u64 = 0,
    geometry_builds: u64 = 0,
    publication_owner: u64 = 0,
    last_native_error: n.Error = .{},

    pub fn create(allocator: std.mem.Allocator, window: z.Window, input: []const Source, options: Options) !*Bridge {
        if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.UnsupportedCapability;
        if (std.Thread.getCurrentId() != window.app.owner) return error.WrongThread;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (builtin.os.tag == .linux) {
            // This first native port has no selection, input, word, affine or
            // auxiliary provider. Reject before retaining any source or memory.
            if (input.len != 1 or !input[0].read_only or input[0].selectable or input[0].focusable or input[0].actions != null or input[0].scroll != null or options.affine_geometry or options.presentation_epochs or options.word_units or options.publication != null or options.auxiliary != null) return error.UnsupportedCapability;
            if (n.zlg_accessibility_host_available(try linuxWindow(scope)) == 0) return error.UnsupportedCapability;
        }
        try model.validateLimits(options.text);
        if (options.auxiliary) |value| {
            if (!ui.capabilities.accessibility) return error.UnsupportedCapability;
            try value.limits.validate();
            if (input.len != 2 or !options.presentation_epochs or (options.affine_geometry and options.publication == null)) return error.UnsupportedAuxiliaryConfiguration;
        }
        if (input.len == 0 or input.len > 2 or options.bytes < baseBytes() + 1024 or options.bytes > 1024 * 1024 * 1024 or options.ranges == 0 or options.ranges > 65536 or options.output_units == 0 or options.output_units > 64 * 1024 * 1024 or options.cells == 0 or options.cells > 16384 or options.carets == 0 or options.carets > 32768 or options.lines == 0 or options.lines > 4096) return error.InvalidLimits;
        if (options.publication != null and (!options.affine_geometry or !options.presentation_epochs)) return error.InvalidPublicationConfiguration;
        var specs: [2]n.Source = undefined;
        var names: [2][128]u16 = undefined;
        for (input, 0..) |source, at| {
            if (std.mem.indexOfScalar(u8, source.name, 0) != null) return error.EmbeddedNul;
            const len = std.unicode.utf8ToUtf16Le(&names[at], source.name) catch return error.InvalidName;
            if (len >= names[at].len) return error.InvalidName;
            specs[at] = .{ .name = &names[at], .name_length = @intCast(len), .read_only = @intFromBool(source.read_only), .selectable = @intFromBool(source.selectable), .focusable = @intFromBool(source.focusable), .scrollable = @intFromBool(source.scroll != null or (source.actions != null and source.actions.?.scroll != null)) };
        }
        var sources: [2]SourceState = undefined;
        var retained: usize = 0;
        errdefer for (sources[0..retained]) |source| source.options.adapter.releaseClient() catch unreachable;
        for (input, 0..) |source, at| {
            const document = try source.adapter.sourceDocument();
            for (sources[0..at]) |previous| if (previous.options.adapter == source.adapter or previous.document == document) return error.DuplicateSource;
            try source.adapter.retainClient();
            sources[at] = .{ .options = source, .document = document };
            sources[at].options.name = ""; // Native create copies the name.
            retained += 1;
        }
        // Pin every source before the first foreign allocator callback. This
        // includes an unbound read-only ghost Adapter in a multi-source view.
        const publication_owner = if (options.publication) |lease| try lease.acquire() else 0;
        var publication_transferred = false;
        errdefer if (!publication_transferred) if (options.publication) |lease| lease.release(publication_owner) catch {};
        const self = try allocator.create(Bridge);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .window = window, .options = options, .owner = std.Thread.getCurrentId(), .count = input.len, .sources = sources, .publication_owner = publication_owner };
        publication_transferred = true;
        errdefer self.releasePublication();
        const cleanup: ?*NativeCleanup = if (builtin.os.tag == .windows) try allocator.create(NativeCleanup) else null;
        var cleanup_transferred = false;
        errdefer if (!cleanup_transferred) if (cleanup) |value| allocator.destroy(value);
        if (window.isClosed() or window.app.phase == .stopping or window.app.phase == .stopped) return error.Closed;
        var native: ?*n.State = null;
        if (builtin.os.tag == .linux) {
            try n.linuxCheck(n.zda_linux_create(&specs, @intCast(input.len), options.bytes - baseBytes(), options.ranges, options.output_units, &self.last_native_error, &native));
        } else {
            try n.check(n.zda_native_create(window.nativeHandle(), &specs, @intCast(input.len), options.bytes - baseBytes(), options.ranges, options.output_units, enqueue, self, &self.last_native_error, &native));
        }
        self.native = native.?;
        if (cleanup) |value| {
            value.* = .{ .node = .{ .task = .{ .context = value, .call = NativeCleanup.run } }, .native = native.?, .allocator = allocator, .app = window.app, .id = window.diagnosticId() };
            self.cleanup = value;
        }
        cleanup_transferred = true;
        errdefer self.detachNative();
        self.budget = .{ .source = allocator, .account = n.zda_native_account(native.?) };
        errdefer n.zda_account_release(self.budget.account);
        if (builtin.os.tag == .linux) {
            // GObject construction/name notification did not borrow Window.
            // Recheck the pinned record before acquiring the generic host.
            _ = try self.live();
            try n.linuxCheck(n.zda_linux_prepare(native.?, try linuxWindow(scope)));
            _ = try self.live();
        }
        if (options.affine_geometry) {
            self.mapping = self.budget.allocator().create(MappingState) catch |err| return self.budget.normalize(err);
            self.mapping.?.* = .{};
        }
        errdefer if (self.mapping) |value| self.budget.allocator().destroy(value);
        if (builtin.os.tag == .windows) {
            if (options.affine_geometry) try n.check(n.zda_native_enable_mapping(native.?));
            if (options.presentation_epochs) try n.check(n.zda_native_enable_presentation(native.?));
            if (options.word_units) try n.check(n.zda_native_enable_words(native.?));
        }
        if (options.auxiliary) |value| {
            self.auxiliary_state = AuxiliaryState.create(self.budget.allocator(), value.limits, options.affine_geometry) catch |err| return self.budget.normalize(err);
        }
        errdefer if (self.auxiliary_state) |value| value.close(self.budget.allocator());
        if (builtin.os.tag == .windows) {
            if (options.auxiliary) |value| try n.check(n.zda_native_enable_auxiliary(native.?, @intCast(value.limits.nodes)));
            if (options.auxiliary != null and options.affine_geometry) try n.check(n.zda_native_enable_auxiliary_mapping(native.?));
        }
        if (window.isClosed() or window.app.phase == .stopping or window.app.phase == .stopped) return error.Closed;
        self.stop_node = .{ .context = self, .stop = stop };
        self.stop_token = try window.app.registerStop(&self.stop_node);
        return self;
    }
    fn baseBytes() usize {
        return @sizeOf(Bridge) + if (builtin.os.tag == .windows) @sizeOf(NativeCleanup) else 0;
    }
    fn linuxWindow(scope: anytype) !*anyopaque {
        // The fake backend has no native field. This boundary deliberately
        // rejects it instead of manufacturing a GTK NativeWindow address.
        if (comptime @hasField(@TypeOf(scope.record.native), "native")) return scope.record.native.native orelse error.Closed;
        return error.UnsupportedCapability;
    }
    fn pinNative(native: *n.State) void {
        if (builtin.os.tag == .linux) n.zda_linux_retain(native) else if (builtin.os.tag == .windows) n.zda_store_retain(native);
    }
    fn unpinNative(native: *n.State) void {
        if (builtin.os.tag == .linux) n.zda_linux_release(native) else if (builtin.os.tag == .windows) n.zda_store_release(native);
    }
    fn sourceCurrent(self: *const Bridge) bool {
        const token = self.context_token orelse return true;
        return token.context.accessibility_source_state.currentGeneration() == token.generation;
    }
    fn currentNative(self: *const Bridge, native: *n.State) !void {
        if (try self.live() != native) return error.Closed;
        if (!self.sourceCurrent()) {
            // Deferred unbound may not yet have run while the source callback
            // is pinned. Revoke native ingress before returning to that tail.
            n.zda_native_begin_close(native);
            return error.Closed;
        }
    }
    fn checked(self: *const Bridge) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.busy) return error.Busy;
    }
    fn live(self: *const Bridge) !*n.State {
        if (self.detached or self.window.isClosed() or self.window.app.phase == .stopping or self.window.app.phase == .stopped) return error.Closed;
        const native = self.native orelse return error.Closed;
        if (builtin.os.tag == .linux) try n.linuxCheck(n.zda_linux_live(native));
        return native;
    }
    pub fn stats(self: *const Bridge) !Stats {
        try self.checked();
        var value: n.Stats = undefined;
        const native = self.native orelse return error.Closed;
        n.zda_native_stats(native, &value);
        return .{ .requested_bytes = value.bytes + baseBytes(), .peak_reserved_bytes = value.peak_bytes + baseBytes(), .byte_limit = self.options.bytes, .host_staging_bytes = value.host_bytes, .states = value.states, .providers = value.providers, .ranges = value.ranges, .blobs = value.blobs, .text_builds = self.text_builds, .geometry_builds = self.geometry_builds };
    }
    pub fn attachContext(self: *Bridge, context: *ui.Context) !void {
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const native = try self.live();
        pinNative(native);
        defer unpinNative(native);
        if (self.context_token != null) return error.AlreadyAttached;
        if (context.window == null or !std.meta.eql(context.window.?, self.window)) return error.ForeignWindow;
        if (builtin.os.tag == .linux and context.backdrop_region != null) return error.UnsupportedGeometry;
        if (self.options.auxiliary != null and !context.attached_semantics_enabled) return error.SemanticsRequired;
        self.busy = true;
        defer self.busy = false;
        try self.positionInner();
        const installed = try context.installAccessibilitySource(.{ .context = self, .query = query, .position_changed = moved, .phase = phase, .unbound = unbound });
        // Old-source disposal can retire this new source synchronously. Never
        // overwrite the unbound notification with an already retired token.
        if (self.detached) return error.Closed;
        self.context_token = installed;
        if (self.window.isClosed() or self.window.app.phase == .stopping or self.window.app.phase == .stopped) {
            _ = try context.clearAccessibilitySource(self.context_token.?);
            return error.Closed;
        }
        if (builtin.os.tag == .linux) {
            try self.currentNative(native);
            try n.linuxCheck(n.zda_linux_mount(native));
            try self.currentNative(native);
        }
    }
    /// Only changed committed text requires a Reader. Readers are borrowed for
    /// this call and belong to caller-owned Snapshots, charged to Document's
    /// separate explicit budget. This never creates a hidden Snapshot/worker.
    pub fn prepareText(self: *Bridge, readers: []const ?d.Reader) !void {
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        _ = try self.live();
        self.busy = true;
        defer self.busy = false;
        self.prepareTextInner(readers) catch |err| return self.budget.normalize(err);
    }
    /// Explicit focus/enabled/selection/composition update. No text mirror is
    /// built or allocated. A committed edit instead returns TextRequired and
    /// withdraws that stale native source until prepareText receives its Reader.
    pub fn updateMetadata(self: *Bridge) !void {
        const readers: [2]?d.Reader = .{ null, null };
        try self.prepareText(readers[0..self.count]);
    }
    fn prepareTextInner(self: *Bridge, readers: []const ?d.Reader) !void {
        if (readers.len != self.count) return error.InvalidSources;
        const native = try self.live();
        pinNative(native);
        defer unpinNative(native);
        var candidate = self.sources;
        var created: [2]bool = .{ false, false };
        defer for (candidate[0..self.count], 0..) |source, at| if (created[at]) n.zda_text_release(source.text);
        var revisions: [2]u64 = undefined;
        for (self.sources[0..self.count], 0..) |source, at| revisions[at] = try source.document.version();
        for (candidate[0..self.count], 0..) |*source, at| {
            const text_version = try source.document.committedTextVersion();
            if (source.text != null and source.stamp == text_version) continue;
            // An observed new committed version must never leave an old ATK
            // string available when Reader capture, quotas or NUL reject it.
            if (builtin.os.tag == .linux) n.zda_native_invalidate(native, @intCast(at));
            const reader = readers[at] orelse {
                n.zda_native_invalidate(native, @intCast(at));
                return error.TextRequired;
            };
            if (try reader.committedTextVersion() != text_version or try reader.version() != revisions[at]) return error.StaleRevision;
            if (try reader.utf16Length() > self.options.output_units) return error.CapacityExceeded;
            var text = try model.Text.create(self.budget.allocator(), reader, self.options.text);
            defer text.deinit();
            try self.currentNative(native);
            if (builtin.os.tag == .linux and std.mem.indexOfScalar(u16, text.utf16, 0) != null) return error.EmbeddedNul;
            const input: n.TextInput = .{ .text_version = text.stamp.text_version, .text = text.utf16.ptr, .scalars = text.scalars.ptr, .paragraphs = text.paragraphs.ptr, .text_length = @intCast(text.utf16.len), .scalar_count = @intCast(text.scalars.len), .paragraph_count = @intCast(text.paragraphs.len) };
            try n.check(n.zda_native_text(native, &input, &source.text));
            source.stamp = text_version;
            created[at] = true;
        }
        var meta: [2]n.Metadata = undefined;
        var selections: [2][64]n.Selection = undefined;
        try self.metadata(candidate[0..self.count], &meta, &selections);
        try self.validate(revisions);
        try self.currentNative(native);
        const texts: [2]?*n.Text = .{ candidate[0].text, if (self.count == 2) candidate[1].text else null };
        try n.check(n.zda_native_publish(native, &texts, &meta, @intCast(self.count)));
        if (builtin.os.tag == .linux) {
            try self.currentNative(native);
            self.validate(revisions) catch |err| {
                n.zda_native_invalidate(native, 0);
                return err;
            };
        }
        for (candidate[0..self.count], 0..) |source, at| if (created[at]) {
            const old = self.sources[at].text;
            self.sources[at].text = source.text;
            self.sources[at].stamp = source.stamp;
            created[at] = false;
            self.text_builds += 1;
            n.zda_text_release(old);
        };
    }
    fn metadata(self: *Bridge, sources: []const SourceState, output: *[2]n.Metadata, storage: *[2][64]n.Selection) !void {
        const state = try self.window.state();
        for (sources, 0..) |source, at| {
            if (source.stamp != try source.document.committedTextVersion()) return error.TextRequired;
            var buffer: [64]d.Selection = undefined;
            const selected = try source.document.selections(&buffer);
            for (selected.items, 0..) |selection, index| storage[at][index] = .{ .anchor = @intCast(try source.document.utf16Offset(selection.anchor)), .caret = @intCast(try source.document.utf16Offset(selection.caret)) };
            output[at] = .{ .text_version = source.stamp, .revision = try source.document.version(), .selections = &storage[at], .selection_count = @intCast(selected.items.len), .primary = @intCast(selected.primary), .focused = @intFromBool(state.focused and try source.options.adapter.isBound()), .enabled = @intFromBool(state.enabled and !state.modal_blocked), .composing = @intFromBool(try source.document.composition() != null) };
        }
    }
    fn validate(self: *const Bridge, revisions: [2]u64) !void {
        _ = try self.live();
        for (self.sources[0..self.count], 0..) |source, at| if (try source.document.version() != revisions[at]) return error.StaleRevision;
    }
    /// Prepare native-owned visible geometry outside paint. Filters describe
    /// actual projected ghost paragraphs; null means the source is fully drawn.
    /// All sources swap as one candidate, including explicit empty geometry.
    pub fn prepareGeometry(self: *Bridge, filters: []const ?[]const usize) !void {
        if (filters.len > 2) return error.InvalidSources;
        var selections: [2]GeometrySelection = undefined;
        for (filters, selections[0..filters.len]) |filter, *selection| selection.* = if (filter) |paragraphs| .{ .paragraphs = paragraphs } else .all;
        return self.prepareGeometrySelected(selections[0..filters.len], 0);
    }
    /// Hidden sources retain full logical text but export no visible geometry.
    /// A presentation-scoped bridge requires a nonzero candidate epoch.
    pub fn prepareGeometrySelected(self: *Bridge, selections: []const GeometrySelection, epoch: u64) !void {
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const native = try self.live();
        pinNative(native);
        defer unpinNative(native);
        if (selections.len != self.count) return error.InvalidSources;
        if (self.options.presentation_epochs != (epoch != 0)) return error.InvalidEpoch;
        self.busy = true;
        defer self.busy = false;
        try self.positionInner();
        self.prepareGeometryInner(native, selections) catch |err| {
            const failure = self.budget.normalize(err);
            if (builtin.os.tag == .windows) {
                var stale = false;
                self.currentNative(native) catch {
                    stale = true;
                };
                for (self.sources[0..self.count]) |source| {
                    const version = source.document.committedTextVersion() catch {
                        stale = true;
                        continue;
                    };
                    if (version != source.stamp) stale = true;
                }
                if (stale) self.withdrawWindows(native);
            }
            return failure;
        };
        self.currentNative(native) catch |err| {
            if (builtin.os.tag == .windows) self.withdrawWindows(native);
            return err;
        };
        self.geometryCurrent() catch |err| {
            if (builtin.os.tag == .windows) self.withdrawWindows(native);
            return err;
        };
        self.pending_epoch = epoch;
    }
    fn prepareGeometryInner(self: *Bridge, native: *n.State, selections: []const GeometrySelection) !void {
        var revisions: [2]u64 = undefined;
        var projections: [2]u64 = undefined;
        var scales: [2]f32 = .{ 0, 0 };
        var bounds: [2]ui.Rect = @splat(.{ .x = 0, .y = 0, .width = 0, .height = 0 });
        var candidates: [2]?*n.Geometry = .{ null, null };
        var hidden: [2]bool = .{ false, false };
        defer for (candidates) |candidate| n.zda_geometry_release(candidate);
        for (self.sources[0..self.count], 0..) |source, at| {
            revisions[at] = try source.document.version();
            if (selections[at] == .hidden) {
                hidden[at] = true;
                projections[at] = 0;
                continue;
            }
            const filter: ?[]const usize = switch (selections[at]) {
                .all => null,
                .paragraphs => |items| items,
                .hidden => unreachable,
            };
            if (!self.options.affine_geometry and try source.options.adapter.hasCommittedSpace()) return error.UnsupportedGeometry;
            if (try source.document.composition() != null) {
                projections[at] = 0;
                continue;
            }
            if (source.stamp != try source.document.committedTextVersion()) return error.TextRequired;
            const cells = try self.budget.allocator().alloc(e.GeometryCell, self.options.cells);
            defer self.budget.allocator().free(cells);
            const exported = try source.options.adapter.preparedGeometry(revisions[at], cells, .{ .paragraphs = filter });
            const carets = try self.budget.allocator().alloc(e.GeometryCaret, self.options.carets);
            defer self.budget.allocator().free(carets);
            const lines = try self.budget.allocator().alloc(e.GeometryLine, self.options.lines);
            defer self.budget.allocator().free(lines);
            const positions = try source.options.adapter.preparedCarets(revisions[at], carets, lines, .{ .paragraphs = filter });
            if (positions.projection_version != exported.projection_version or positions.scale != exported.scale or !std.meta.eql(positions.bounds, exported.bounds)) return error.StaleGeometry;
            projections[at] = exported.projection_version;
            scales[at] = exported.scale;
            bounds[at] = exported.bounds;
            const copied = try self.budget.allocator().alloc(n.Cell, exported.cells.len);
            defer self.budget.allocator().free(copied);
            for (exported.cells, copied) |cell, *target| target.* = .{ .start = @intCast(try source.document.utf16Offset(cell.range.start)), .end = @intCast(try source.document.utf16Offset(cell.range.end)), .rectangle = rect(cell.rect) };
            const copied_carets = try self.budget.allocator().alloc(n.Caret, positions.carets.len);
            defer self.budget.allocator().free(copied_carets);
            for (positions.carets, copied_carets) |caret, *target| target.* = .{ .position = @intCast(try source.document.utf16Offset(caret.position)), .affinity = @intFromEnum(caret.affinity), .rectangle = rect(caret.rect) };
            const copied_lines = try self.budget.allocator().alloc(n.Line, positions.lines.len);
            defer self.budget.allocator().free(copied_lines);
            for (positions.lines, copied_lines) |line, *target| target.* = .{ .first = @intCast(line.first), .count = @intCast(line.count), .rectangle = rect(line.rect) };
            const input: n.GeometryInput = .{ .text_version = source.stamp, .projection_version = exported.projection_version, .bounds = rect(exported.bounds), .cells = copied.ptr, .cell_count = @intCast(copied.len), .scale = exported.scale, .carets = copied_carets.ptr, .caret_count = @intCast(copied_carets.len), .lines = copied_lines.ptr, .line_count = @intCast(copied_lines.len) };
            try self.currentNative(native);
            candidates[at] = try self.prepareHit(native, at, source, revisions[at], &input, filter != null);
        }
        try self.validate(revisions);
        try self.currentNative(native);
        for (self.sources[0..self.count], 0..) |source, at| if (projections[at] != 0 and try source.options.adapter.projectionVersion() != projections[at]) return error.StaleGeometry;
        std.mem.swap([2]?*n.Geometry, &self.pending, &candidates);
        self.pending_revision = revisions;
        self.pending_projection = projections;
        self.pending_scale = scales;
        self.pending_bounds = bounds;
        self.pending_hidden = hidden;
        self.armed = false;
        if (self.mapping) |value| value.mask = 0;
        self.geometry_builds += 1;
    }
    // Full input data is prepared only here, outside paint. Both native
    // consumers own a copy; no Layout or host buffer crosses a getter ABI.
    noinline fn prepareHit(self: *Bridge, native: *n.State, index: usize, source: SourceState, revision: u64, geometry: *const n.GeometryInput, filtered: bool) !?*n.Geometry {
        const allocator = self.budget.allocator();
        const blocks = try allocator.alloc(e.HitBlock, 24);
        defer allocator.free(blocks);
        const lines = try allocator.alloc(e.HitLine, self.options.lines);
        defer allocator.free(lines);
        const stops = try allocator.alloc(e.HitStop, self.options.carets);
        defer allocator.free(stops);
        const projected = (try source.options.adapter.status()).projection_active;
        const placements = try allocator.alloc(e.HitPlacement, if (projected) 24 * 32 else 0);
        defer allocator.free(placements);
        try self.currentNative(native);
        const hit = try source.options.adapter.preparedHit(revision, .{ .blocks = blocks, .lines = lines, .stops = stops, .placements = placements });
        if (hit.text_version != source.stamp or hit.projection_version != geometry.projection_version or hit.scale != geometry.scale or
            @as(f64, hit.packet.bounds.x) != geometry.bounds.x or @as(f64, hit.packet.bounds.y) != geometry.bounds.y or @as(f64, hit.packet.bounds.width) != geometry.bounds.width or @as(f64, hit.packet.bounds.height) != geometry.bounds.height) return error.StaleGeometry;
        for (stops[0..hit.packet.stop_count]) |*item| item.position = try source.document.utf16Offset(@intCast(item.position));
        const input: n.HitInput = .{ .revision = revision, .text_version = hit.text_version, .projection_version = hit.projection_version, .geometry_generation = hit.geometry_generation, .scale = hit.scale, .domain = @intFromBool(filtered), .packet = hit.packet };
        try self.currentNative(native);
        if (try source.document.version() != revision or try source.options.adapter.projectionVersion() != hit.projection_version) return error.StaleGeometry;
        var result: ?*n.Geometry = null;
        errdefer n.zda_geometry_release(result);
        if (builtin.os.tag == .windows) {
            try n.check(n.zda_native_geometry_hit(native, @intCast(index), geometry, &input, &result));
        } else try n.check(n.zda_linux_geometry_hit(native, geometry, &input, &result));
        try self.currentNative(native);
        if (try source.document.version() != revision or try source.options.adapter.projectionVersion() != hit.projection_version) return error.StaleGeometry;
        return result;
    }
    const PublicationFrame = struct { source: u64, candidate: u64 };
    fn publicationFrame(self: *const Bridge) !PublicationFrame {
        const token = self.context_token orelse return error.NotAttached;
        return .{ .source = token.generation, .candidate = token.context.accessibility_source_state.frame_candidate };
    }
    fn publicationCurrent(self: *const Bridge, native: *n.State, frame: PublicationFrame) !void {
        try self.currentNative(native);
        const token = self.context_token orelse return error.NotAttached;
        if (token.generation != frame.source or !token.context.accessibility_source_state.isCommittedFrame(frame.source, frame.candidate)) return error.StaleGeometry;
        try self.geometryCurrent();
        for (self.pending_scale[0..self.count]) |scale| if (scale != 0 and scale != self.native_scale) return error.StaleGeometry;
        if (self.mapping) |mapping| for (mapping.recorded[0..self.count]) |*recorded| try recorded.checkCommitted(token.context);
    }
    // Capture every borrowed owner decision before the C-only retirement can
    // reach a final COM free. No Bridge/Context/Document access follows it.
    fn withdrawWindows(self: *Bridge, native: *n.State) void {
        self.armed = false;
        if (self.options.publication) |lease| _ = lease.withdraw() catch 0;
        var invalid_text: u32 = 0;
        for (self.sources[0..self.count], 0..) |source, at| {
            const version = source.document.committedTextVersion() catch {
                invalid_text |= @as(u32, 1) << @intCast(at);
                continue;
            };
            if (version != source.stamp) invalid_text |= @as(u32, 1) << @intCast(at);
        }
        n.zda_native_withdraw_geometry(native, invalid_text);
    }
    /// Call after recording every source's matching Prepared text in this Frame.
    /// It only arms owned staging; the Context's successful-front hook publishes.
    /// No Frame, host slice or Adapter pointer is retained by native providers.
    pub fn recordGeometry(self: *Bridge, frame: *ui.Frame) !void {
        if (self.mapping != null) {
            for (0..self.count) |at| try self.recordSourceGeometry(frame, at);
            return;
        }
        try self.checked();
        _ = try self.live();
        const token = self.context_token orelse return error.NotAttached;
        if (frame.context != token.context) return error.ForeignFrame;
        if (builtin.os.tag == .linux and (!frame.context.painting or !self.sourceCurrent() or frame.context.frame_accessibility_source != token.generation)) return error.StaleGeometry;
        if (frame.offset_depth != 0 or frame.transforms != null) return error.UnsupportedGeometry;
        if (frame.clipBounds()) |clip| for (self.pending_bounds[0..self.count], 0..) |bounds, at| {
            if (self.pending_projection[at] != 0 and !std.meta.eql(ui.layout.intersect(bounds, clip), bounds)) return error.UnsupportedGeometry;
        };
        if (frame.failure) |err| return err;
        try self.geometryCurrent();
        for (self.pending_scale[0..self.count]) |scale| if (scale != 0 and scale != frame.size.scale) return error.StaleGeometry;
        self.armed = true;
    }
    /// Sole source of auxiliary labels, typed action keys and fixed patterns.
    /// Call outside paint after preparing the matching full-text geometry.
    pub fn prepareAuxiliary(self: *Bridge, plan: auxiliary.SemanticPlan) !void {
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const native = try self.live();
        const state = self.auxiliary_state orelse return error.UnsupportedCapability;
        const options = self.options.auxiliary.?;
        const bytes = try auxiliary.validate(plan, options.limits);
        for (plan.nodes) |node| if (node.focusable and options.handler.focus == null) return error.FocusHandlerRequired;
        self.busy = true;
        defer self.busy = false;
        const allocator = self.budget.allocator();
        const copied = allocator.alloc(auxiliary.Node, plan.nodes.len) catch |err| return self.budget.normalize(err);
        var transferred = false;
        defer if (!transferred) allocator.free(copied);
        const labels = allocator.alloc(u8, bytes) catch |err| return self.budget.normalize(err);
        defer if (!transferred) allocator.free(labels);
        const converted = allocator.alloc(u16, bytes) catch |err| return self.budget.normalize(err);
        defer allocator.free(converted);
        const inputs = allocator.alloc(n.AuxNode, plan.nodes.len) catch |err| return self.budget.normalize(err);
        defer allocator.free(inputs);
        var used: usize = 0;
        var units: usize = 0;
        for (plan.nodes, copied, inputs) |node, *target, *input| {
            const name = labels[used..][0..node.name.len];
            @memcpy(name, node.name);
            used += name.len;
            target.* = node;
            target.name = name;
            var parent: u32 = std.math.maxInt(u32);
            if (node.parent) |id| for (plan.nodes, 0..) |possible, at| if (possible.frame_id == id) {
                parent = @intCast(at);
                break;
            };
            const len = try std.unicode.utf8ToUtf16Le(converted[units..], name);
            input.* = .{ .key = node.key, .frame_id = node.frame_id, .parent = parent, .name_start = @intCast(units), .name_length = @intCast(len), .expanded = @as(u32, @intFromBool(node.expanded)) | (@as(u32, @intFromBool(node.focusable)) << 1) };
            units += len;
        }
        _ = try self.live();
        try self.geometryCurrent();
        var candidate: ?*n.AuxPlan = null;
        try n.check(n.zda_native_auxiliary(native, inputs.ptr, @intCast(inputs.len), converted.ptr, @intCast(units), &candidate));
        const old = state.native;
        const old_plan = state.plan;
        const old_labels = state.plan_labels;
        state.native = candidate;
        state.plan = copied;
        state.plan_labels = labels;
        state.recorded = false;
        transferred = true;
        n.zda_auxiliary_release(old);
        allocator.free(old_plan);
        allocator.free(old_labels);
    }
    /// Verify the drawn explicit subtree against the prepared semantic plan.
    /// This copies POD geometry only, without allocation or native queries.
    pub fn recordAuxiliary(self: *Bridge, frame: *ui.Frame) anyerror!void {
        return self.recordAuxiliaryInner(frame, null);
    }
    /// Typed same-scope controls supply their original local bounds. The real
    /// mapped descriptors must match them exactly after current-offset rebasing.
    /// Nested auxiliary scopes and manually inferred AABBs are rejected.
    pub fn recordAuxiliaryLocal(self: *Bridge, frame: *ui.Frame, expected_bounds: []const ui.Rect) anyerror!void {
        return self.recordAuxiliaryInner(frame, expected_bounds);
    }
    fn recordAuxiliaryInner(self: *Bridge, frame: *ui.Frame, expected_bounds: ?[]const ui.Rect) anyerror!void {
        errdefer |err| frame.failure = frame.failure orelse err;
        if (!ui.capabilities.accessibility) return error.UnsupportedCapability;
        try self.checked();
        _ = try self.live();
        const state = self.auxiliary_state orelse return error.UnsupportedCapability;
        state.recorded = false;
        if (state.plan.len == 0 or state.native == null) return error.AuxiliaryRequired;
        const token = self.context_token orelse return error.NotAttached;
        if (frame.context != token.context) return error.ForeignFrame;
        if (!frame.context.painting) return error.NoFrame;
        if (state.affine == null and (frame.transforms != null or frame.context.semantic_tree.mapped != null)) return error.UnsupportedGeometry;
        if (state.affine != null and (expected_bounds == null or expected_bounds.?.len != state.plan.len)) return error.UnsupportedGeometry;
        if (frame.failure) |err| return @as(anyerror!void, err);
        try self.geometryCurrent();
        if (frame.size.scale != self.native_scale) return error.StaleGeometry;
        const nodes = try frame.context.semantic_tree.exportSubtree(state.plan[0].frame_id, state.nodes, state.labels);
        if (nodes.len != state.plan.len) return error.AuxiliaryPlanMismatch;
        for (nodes, state.plan, state.geometry[0..nodes.len], 0..) |node, expected, *target, at| {
            if (node.id != expected.frame_id or node.parent != (if (at == 0) ui.accessibility.root_id else expected.parent) or node.role != expected.role() or !std.mem.eql(u8, node.name, expected.name) or node.value.len != 0 or node.read_only or node.checked) return error.AuxiliaryPlanMismatch;
            const rectangle = node.bounds;
            target.* = .{ .x = rectangle.x, .y = rectangle.y, .width = rectangle.width, .height = rectangle.height, .flags = @as(u32, @intFromBool(node.enabled)) | (@as(u32, @intFromBool(node.focused)) << 1) | (@as(u32, @intFromBool(rectangle.width > 0 and rectangle.height > 0)) << 2) };
        }
        if (state.affine) |mapping| try self.recordAuxiliaryMapped(frame, state, mapping, expected_bounds.?);
        state.recorded = true;
    }
    // Keep bounded affine scratch off the identity auxiliary call stack even in
    // Debug. This helper is entered only by the explicit affine configuration.
    noinline fn recordAuxiliaryMapped(self: *Bridge, frame: *ui.Frame, state: *AuxiliaryState, mapping: *AuxiliaryMapping, expected_bounds: []const ui.Rect) !void {
        var local: [ui.accessibility.max_nodes]ui.Rect = undefined;
        var ids: [ui.accessibility.max_nodes]u64 = undefined;
        for (state.plan, ids[0..state.plan.len]) |node, *id| id.* = node.frame_id;
        try frame.semanticLocalBounds(ids[0..state.plan.len], local[0..state.plan.len]);
        for (local[0..state.plan.len], expected_bounds) |actual, expected| if (!std.meta.eql(actual, expected)) return error.AuxiliaryPlanMismatch;
        const body = self.mapping.?;
        if (body.mask != 3) return error.GeometryRequired;
        const reference: ui.affine.Ref = if (frame.transforms) |workspace| workspace.reference else .{};
        for (body.reference[0..self.count]) |recorded| if (!std.meta.eql(reference, recorded)) return error.UnsupportedGeometry;
        var left: f64 = local[0].x;
        var top: f64 = local[0].y;
        var right = left + local[0].width;
        var bottom = top + local[0].height;
        for (local[1..state.plan.len]) |rectangle| {
            right = @max(right, @as(f64, rectangle.x) + rectangle.width);
            bottom = @max(bottom, @as(f64, rectangle.y) + rectangle.height);
            left = @min(left, rectangle.x);
            top = @min(top, rectangle.y);
        }
        // The shared capture may conservatively enclose a non-f32 edge;
        // each actual rectangle is still clipped and hit-tested exactly.
        const union_bounds: ui.Rect = .{ .x = @floatCast(left), .y = @floatCast(top), .width = try outwardExtent(right - left), .height = try outwardExtent(bottom - top) };
        var candidate: ui.CoordinateMapping = undefined;
        try frame.coordinateMapping(union_bounds, &candidate);
        for (body.recorded[0..self.count]) |*recorded| if (!sameScope(&candidate, recorded)) return error.UnsupportedGeometry;
        mapping.recorded = candidate;
        mapping.native = copyMapping(&candidate);
        for (local[0..state.plan.len], state.geometry[0..state.plan.len]) |rectangle, *target| {
            target.x = rectangle.x;
            target.y = rectangle.y;
            target.width = rectangle.width;
            target.height = rectangle.height;
            target.flags = (target.flags & 3) | (@as(u32, @intFromBool(rectangle.width > 0 and rectangle.height > 0)) << 2);
        }
    }
    pub fn retainAuxiliaryProvider(self: *Bridge, key: auxiliary.Key) !*anyopaque {
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        try self.checked();
        return n.zda_native_auxiliary_provider(try self.live(), &key) orelse error.ElementNotAvailable;
    }
    /// Only the successful native front is consulted. Pending plans and failed
    /// frames cannot lend a new identity to an older accepted input ID.
    pub fn acceptedAuxiliary(self: *Bridge, frame_id: u64) !AcceptedAuxiliary {
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        try self.checked();
        var value: n.AuxAccepted = undefined;
        try n.check(n.zda_native_auxiliary_accepted(try self.live(), frame_id, &value));
        return self.acceptedAuxiliaryValue(value);
    }
    pub fn acceptedAuxiliaryKey(self: *Bridge, key: auxiliary.Key) !AcceptedAuxiliary {
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        // Read-only accepted-front lookup is also used inside the retained
        // owner focus callback; it never lends the pending preparation bank.
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        var value: n.AuxAccepted = undefined;
        try n.check(n.zda_native_auxiliary_accepted_key(try self.live(), &key, &value));
        return self.acceptedAuxiliaryValue(value);
    }
    fn acceptedAuxiliaryValue(self: *const Bridge, value: n.AuxAccepted) !AcceptedAuxiliary {
        try self.validatePublication(value.publication);
        return .{ .key = value.key, .frame_id = value.frame_id, .epoch = value.presentation_epoch, .enabled = value.flags & 1 != 0, .focused = value.flags & 2 != 0, .visible = value.flags & 4 != 0, .focusable = value.flags & 8 != 0, .expanded = value.flags & 16 != 0 };
    }
    fn validatePublication(self: *const Bridge, value: n.Publication) !void {
        const lease = self.options.publication orelse return;
        const accepted = try lease.snapshot();
        if (accepted.generation != value.generation or !std.meta.eql(accepted.stamp, @as(e.PresentationLease.Stamp, .{ .publication = value.publication, .source = value.source, .candidate = value.candidate, .space_epoch = value.space_epoch, .space_generation = value.space_generation }))) return error.StalePresentation;
    }
    fn sameScope(a: *const ui.CoordinateMapping, b: *const ui.CoordinateMapping) bool {
        return a.context == b.context and std.meta.eql(a.window, b.window) and std.meta.eql(a.region, b.region) and a.source == b.source and a.candidate == b.candidate and a.epoch == b.epoch and a.space_generation == b.space_generation and std.meta.eql(a.space, b.space);
    }
    fn copyMapping(candidate: *const ui.CoordinateMapping) n.Mapping {
        const matrix = candidate.space.to_window;
        const inverse = candidate.space.to_local;
        var copied: n.Mapping = .{ .forward = .{ matrix.xx, matrix.yx, matrix.xy, matrix.yy, matrix.x0, matrix.y0 }, .inverse = .{ inverse.xx, inverse.yx, inverse.xy, inverse.yy, inverse.x0, inverse.y0 }, .count = @intCast(candidate.visible.len) };
        for (candidate.visible.points(), copied.polygon[0..candidate.visible.len]) |point, *target| target.* = .{ .x = point.x, .y = point.y };
        return copied;
    }
    fn outwardExtent(value: f64) !f32 {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidGeometry;
        var result: f32 = @floatCast(value);
        if (!std.math.isFinite(result)) return error.InvalidGeometry;
        if (@as(f64, result) < value) result = @bitCast(@as(u32, @bitCast(result)) + 1);
        if (!std.math.isFinite(result)) return error.InvalidGeometry;
        return result;
    }
    /// Record each source at exactly its drawing scope. All source mappings
    /// must belong to the same candidate Frame; no allocation or native query.
    pub fn recordSourceGeometry(self: *Bridge, frame: *ui.Frame, index: usize) !void {
        try self.checked();
        _ = try self.live();
        const token = self.context_token orelse return error.NotAttached;
        if (frame.context != token.context) return error.ForeignFrame;
        const value = self.mapping orelse return error.UnsupportedGeometry;
        if (index >= self.count) return error.InvalidSources;
        try self.geometryCurrent();
        const scale = self.pending_scale[index];
        if (scale != 0 and scale != frame.size.scale) return error.StaleGeometry;
        var candidate: ui.CoordinateMapping = undefined;
        try frame.coordinateMapping(self.pending_bounds[index], &candidate);
        value.recorded[index] = candidate;
        value.native[index] = copyMapping(&candidate);
        value.reference[index] = if (frame.transforms) |workspace| workspace.reference else .{};
        value.mask |= @as(u2, 1) << @intCast(index);
        self.armed = value.mask == (if (self.count == 2) @as(u2, 3) else @as(u2, 1));
    }
    fn geometryCurrent(self: *const Bridge) !void {
        try self.validate(self.pending_revision);
        for (self.sources[0..self.count], 0..) |source, at| {
            if (self.pending_hidden[at]) continue;
            if (self.pending_projection[at] == 0) {
                if (try source.document.composition() == null) return error.GeometryRequired;
            } else if (try source.options.adapter.projectionVersion() != self.pending_projection[at]) return error.StaleGeometry;
        }
    }
    pub fn positionChanged(self: *Bridge) !void {
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        try self.positionInner();
    }
    fn positionInner(self: *Bridge) !void {
        const native = try self.live();
        if (builtin.os.tag == .linux) {
            pinNative(native);
            defer unpinNative(native);
            var scale: f64 = undefined;
            try n.linuxCheck(n.zda_linux_position(native, &scale));
            try self.currentNative(native);
            self.native_scale = scale;
        } else {
            var origin: c.POINT = .{ .x = 0, .y = 0 };
            const hwnd: c.HWND = @ptrCast(self.window.nativeHandle());
            if (hwnd == null or c.ClientToScreen(hwnd, &origin) == 0) return error.Closed;
            const scale = @as(f64, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
            try n.check(n.zda_native_position(native, @floatFromInt(origin.x), @floatFromInt(origin.y), scale));
            self.native_scale = scale;
        }
    }
    pub fn retainProvider(self: *Bridge, source: ?usize) !*anyopaque {
        try self.checked();
        const native = try self.live();
        if (source) |index| if (index >= self.count) return error.InvalidSources;
        return n.zda_native_provider(native, if (source) |index| @intCast(index) else std.math.maxInt(u32)) orelse error.NativeUnavailable;
    }
    pub fn detach(self: *Bridge) !void {
        try self.checked();
        const scope = self.window.app.beginTeardownCallback();
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        try self.detachInner(false);
    }
    pub fn close(self: *Bridge) !void {
        try self.checked();
        const scope = self.window.app.beginTeardownCallback();
        defer scope.end();
        const count = self.count;
        var adapters: [2]*e.Adapter = undefined;
        for (self.sources[0..count], 0..) |source, at| adapters[at] = source.options.adapter;
        for (self.sources[0..self.count]) |source| _ = try source.options.adapter.sourceDocument();
        self.busy = true;
        errdefer self.busy = false;
        try self.detachInner(false);
        for (self.sources[0..self.count]) |source| {
            n.zda_text_release(source.text);
        }
        for (self.pending) |candidate| n.zda_geometry_release(candidate);
        if (self.mapping) |value| {
            self.mapping = null;
            self.budget.allocator().destroy(value);
        }
        if (self.auxiliary_state) |value| {
            self.auxiliary_state = null;
            value.close(self.budget.allocator());
        }
        const allocator = self.allocator;
        const account = self.budget.account;
        allocator.destroy(self);
        n.zda_account_release(account);
        // These clients cover all foreign frees, including the owner shell.
        // No self access or fallible cleanup is permitted after its destruction.
        for (adapters[0..count]) |adapter| adapter.releaseClient() catch unreachable;
    }
    fn detachInner(self: *Bridge, stopping: bool) !void {
        if (!stopping and self.stop_token != null and self.stop_node.state != .registered) return error.Busy;
        if (self.context_token) |token| {
            _ = try token.context.clearAccessibilitySource(token);
            if (self.context_token != null) return error.Busy;
        }
        if (!stopping) if (self.stop_token) |token| {
            if (!try self.window.app.cancelStop(token)) return error.Busy;
            self.stop_token = null;
        };
        self.detachNative();
    }
    fn detachNative(self: *Bridge) void {
        self.releasePublication();
        const native = self.native orelse return;
        n.zda_native_begin_close(native);
        self.native = null;
        self.detached = true;
        if (builtin.os.tag == .linux) {
            // C-only provider ownership is independent of App/allocator life.
            _ = n.zda_native_disconnect(native);
            return;
        }
        const cleanup = self.cleanup.?;
        self.cleanup = null;
        self.window.app.deferCleanup(&cleanup.node);
    }
    fn releasePublication(self: *Bridge) void {
        const publisher = self.publication_owner;
        if (publisher == 0) return;
        self.publication_owner = 0;
        const lease = self.options.publication.?;
        self.options.publication = null;
        lease.release(publisher) catch {};
    }
    fn stop(ptr: *anyopaque) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        if (self.busy) return error.Busy;
        self.busy = true;
        defer self.busy = false;
        try self.detachInner(true);
        self.stop_token = null;
    }
    fn query(ptr: *anyopaque, window: z.Window, wp: usize, lp: isize) ?isize {
        if (builtin.os.tag != .windows) return null;
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        if (lp != -25 or self.busy or self.detached or window.isClosed()) return null;
        const native = self.native orelse return null;
        self.busy = true;
        defer self.busy = false;
        return n.zda_native_object(native, wp, lp);
    }
    fn moved(ptr: *anyopaque, _: z.Window) void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        self.positionChanged() catch |err| self.report(err);
    }
    fn phase(ptr: *anyopaque, _: z.Window, value: ui.AccessibilityPhase) void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        if (self.busy or self.detached) return;
        if (value == .frame_begin) {
            self.armed = false;
            if (self.options.publication) |lease| lease.discardCandidate();
            if (self.auxiliary_state) |state| state.recorded = false;
            if (self.mapping) |mapping| mapping.mask = 0;
            return;
        }
        const native = self.native orelse return;
        pinNative(native);
        defer unpinNative(native);
        self.busy = true;
        defer self.busy = false;
        var valid = self.armed;
        self.geometryCurrent() catch {
            valid = false;
        };
        for (self.pending_scale[0..self.count]) |scale| if (scale != 0 and scale != self.native_scale) {
            valid = false;
        };
        const empty: [2]?*n.Geometry = .{ null, null };
        if (builtin.os.tag == .linux) {
            self.currentNative(native) catch return;
            const token = self.context_token orelse return;
            const source = &token.context.accessibility_source_state;
            if (!source.isCommittedFrame(token.generation, source.frame_candidate)) valid = false;
            n.check(n.zda_native_publish_geometry(native, if (valid) &self.pending else &empty, @intCast(self.count))) catch |err| {
                self.report(err);
            };
            // Notifications can replace this Context source or close Window.
            // A State pin alone cannot authorize the borrowed Zig tail.
            self.currentNative(native) catch return;
            self.geometryCurrent() catch {
                // The notification may edit Document or change its prepared
                // projection without replacing Window/Context source identity.
                // The observed revision cannot keep either old bank available.
                n.zda_native_invalidate(native, 0);
                self.armed = false;
                return;
            };
            self.armed = false;
            return;
        }
        if (valid) if (self.mapping) |mapping| for (mapping.recorded[0..self.count]) |*recorded| recorded.checkCommitted(self.context_token.?.context) catch {
            valid = false;
        };
        if (self.auxiliary_state) |state| if (state.recorded) if (state.affine) |mapping| {
            mapping.recorded.checkCommitted(self.context_token.?.context) catch {
                state.recorded = false;
            };
            if (!sameScope(&mapping.recorded, &self.mapping.?.recorded[0])) state.recorded = false;
        };
        self.currentNative(native) catch |err| {
            self.report(err);
            self.withdrawWindows(native);
            return;
        };
        const published_frame = self.publicationFrame() catch |err| {
            self.report(err);
            self.withdrawWindows(native);
            return;
        };
        if (self.options.presentation_epochs) {
            // Exact owner association precedes even C publication. In
            // particular scratch C cannot be published by an outer B tail.
            if (valid) if (self.options.publication) |lease| {
                const recorded = self.mapping.?.recorded[0];
                const generation = recorded.space_generation;
                if (generation == null or !lease.candidateMatches(.{ .publication = self.pending_epoch, .source = recorded.source, .candidate = recorded.candidate, .space_epoch = recorded.epoch, .space_generation = generation orelse 0 })) valid = false;
            };
            // Revoke before outbound native publication. No business callback
            // runs here; failed front never reaches this successful-front hook.
            const publication_generation = if (self.options.publication) |lease| lease.begin(self.publication_owner) catch |err| failed: {
                valid = false;
                self.report(err);
                break :failed @as(u64, 0);
            } else 0;
            const mappings: ?[*]const n.Mapping = if (valid and self.mapping != null) &self.mapping.?.native else null;
            const result = if (self.auxiliary_state) |state| result: {
                const recorded = valid and state.recorded;
                if (state.affine) |mapping| {
                    const publication: n.Publication = if (recorded) publication: {
                        const body = &self.mapping.?.recorded[0];
                        break :publication .{ .generation = publication_generation, .publication = self.pending_epoch, .source = body.source, .candidate = body.candidate, .space_epoch = body.epoch, .space_generation = body.space_generation orelse 0 };
                    } else .{};
                    break :result n.zda_native_publish_auxiliary_mapped(native, if (valid) &self.pending else &empty, mappings, @intCast(self.count), if (valid) self.pending_epoch else 0, if (recorded) state.native else null, if (recorded) state.geometry.ptr else null, if (recorded) @intCast(state.plan.len) else 0, self.native_scale, if (recorded) &mapping.native else null, if (recorded) &publication else null);
                }
                break :result n.zda_native_publish_auxiliary(native, if (valid) &self.pending else &empty, @intCast(self.count), if (valid) self.pending_epoch else 0, if (recorded) state.native else null, if (recorded) state.geometry.ptr else null, if (recorded) @intCast(state.plan.len) else 0, self.native_scale);
            } else n.zda_native_publish_presented(native, if (valid) &self.pending else &empty, mappings, @intCast(self.count), if (valid) self.pending_epoch else 0);
            n.check(result) catch |err| {
                self.report(err);
                self.withdrawWindows(native);
                return;
            };
            if (valid) self.publicationCurrent(native, published_frame) catch |err| {
                self.report(err);
                self.withdrawWindows(native);
                return;
            };
            if (valid) if (self.options.publication) |lease| {
                const recorded = self.mapping.?.recorded[0];
                if (recorded.space_generation) |generation| {
                    lease.commit(self.publication_owner, publication_generation, .{ .publication = self.pending_epoch, .source = recorded.source, .candidate = recorded.candidate, .space_epoch = recorded.epoch, .space_generation = generation }) catch |err| {
                        self.report(err);
                        self.withdrawWindows(native);
                        return;
                    };
                } else {
                    self.report(error.UnsupportedGeometry);
                    self.withdrawWindows(native);
                    return;
                }
            };
            self.armed = false;
            return;
        }
        const result = if (self.mapping) |mapping| result: {
            if (valid) for (mapping.recorded[0..self.count]) |*recorded| recorded.checkCommitted(self.context_token.?.context) catch {
                valid = false;
            };
            break :result if (valid) n.zda_native_publish_mapped(native, &self.pending, &mapping.native, @intCast(self.count)) else n.zda_native_publish_geometry(native, &empty, @intCast(self.count));
        } else n.zda_native_publish_geometry(native, if (valid) &self.pending else &empty, @intCast(self.count));
        n.check(result) catch |err| {
            self.report(err);
            self.withdrawWindows(native);
            return;
        };
        if (valid) self.publicationCurrent(native, published_frame) catch |err| {
            self.report(err);
            self.withdrawWindows(native);
            return;
        };
        self.armed = false;
    }
    fn unbound(ptr: *anyopaque) void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        self.context_token = null;
        // No outbound COM: safe even when invoked after a WM_GETOBJECT scope.
        self.detachNative();
    }
    fn enqueue(ptr: *anyopaque, action: *anyopaque) callconv(.c) c_int {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        // Native State's lock covers this borrowed Bridge through App.post.
        // Accepted work owns its native action even after Bridge/App ingress closes.
        self.window.app.post(.{ .context = action, .call = dispatch }) catch return 0;
        return 1;
    }
    fn dispatch(ptr: *anyopaque) void {
        defer n.zda_native_finish_action(ptr);
        var auxiliary_action: n.AuxAction = undefined;
        if (n.zda_native_take_auxiliary_action(ptr, &auxiliary_action) != 0) {
            const self: *Bridge = @ptrCast(@alignCast(auxiliary_action.context orelse return));
            const scope = self.window.beginCallback() orelse return;
            defer scope.end();
            if (self.busy or self.detached) return;
            self.busy = true;
            defer self.busy = false;
            self.auxiliaryAction(auxiliary_action) catch |err| self.report(err);
            return;
        }
        var action: n.Action = undefined;
        if (n.zda_native_take_action(ptr, &action) == 0) return;
        const self: *Bridge = @ptrCast(@alignCast(action.context orelse return));
        const scope = self.window.beginCallback() orelse return;
        defer scope.end();
        if (self.busy or self.detached) return;
        self.busy = true;
        defer self.busy = false;
        self.actionInner(action) catch |err| self.report(err);
    }
    fn auxiliaryAction(self: *Bridge, action: n.AuxAction) !void {
        _ = try self.live();
        try self.validatePublication(action.publication);
        const options = self.options.auxiliary orelse return error.NotSupported;
        if (self.pending_epoch != action.presentation_epoch) return error.StalePresentation;
        try self.geometryCurrent();
        const state = try self.window.state();
        if (!state.enabled or state.modal_blocked) return error.Disabled;
        for (self.sources[0..self.count]) |source| if (try source.document.composition() != null) return error.CompositionActive;
        try options.handler.validate(options.handler.context, self.window, action.presentation_epoch, action.key);
        _ = try self.live();
        try self.validatePublication(action.publication);
        try self.geometryCurrent();
        const current = try self.window.state();
        if (!current.enabled or current.modal_blocked) return error.Disabled;
        if (action.kind == 4) {
            const focus = options.handler.focus orelse return error.NotSupported;
            return focus(options.handler.context, self.window, action.key);
        }
        try options.handler.call(options.handler.context, self.window, .{ .key = action.key, .operation = switch (action.kind) {
            1 => .invoke,
            2 => .{ .expanded = true },
            3 => .{ .expanded = false },
            else => return error.NotSupported,
        } });
    }
    fn actionInner(self: *Bridge, action: n.Action) !void {
        _ = try self.live();
        const window_state = try self.window.state();
        if (!window_state.enabled or window_state.modal_blocked) return error.Disabled;
        if (action.source >= self.count) return error.InvalidSources;
        const source = self.sources[action.source];
        if (try source.document.version() != action.revision or try source.document.committedTextVersion() != action.text_version) return error.StaleRevision;
        if (try source.document.composition() != null) return error.CompositionActive;
        if (source.options.actions) |actions| try actions.validate(actions.context, self.window, action.source, action.presentation_epoch);
        _ = try self.live();
        if (try source.document.version() != action.revision) return error.StaleRevision;
        const range: d.Range = .{ .start = try source.document.byteOffsetFromUtf16(action.start), .end = try source.document.byteOffsetFromUtf16(action.end) };
        switch (action.kind) {
            1 => {
                if (!source.options.focusable) return error.NotSupported;
                if (source.options.actions) |actions| {
                    const call = actions.focus orelse return error.NotSupported;
                    try call(actions.context, self.window, action.source);
                } else {
                    if (!try source.options.adapter.isBound()) return error.NotSupported;
                    try self.window.perform(.focus);
                }
            },
            2, 3, 4 => {
                if (!source.options.selectable) return error.NotSupported;
                var selections: [65]d.Selection = undefined;
                var count: usize = 0;
                var primary: usize = 0;
                if (action.kind != 2) {
                    const old = try source.document.selections(selections[0..64]);
                    count = old.items.len;
                    primary = old.primary;
                }
                if (action.kind == 4) {
                    var found: ?usize = null;
                    for (selections[0..count], 0..) |selected, at| if (@min(selected.anchor, selected.caret) == range.start and @max(selected.anchor, selected.caret) == range.end) {
                        found = at;
                        break;
                    };
                    const at = found orelse return error.InvalidSelection;
                    if (count == 1) return error.InvalidSelection;
                    std.mem.copyForwards(d.Selection, selections[at .. count - 1], selections[at + 1 .. count]);
                    count -= 1;
                    if (primary > at) primary -= 1;
                    primary = @min(primary, count - 1);
                } else {
                    if (count == 64) return error.CapacityExceeded;
                    selections[count] = .{ .anchor = range.start, .caret = range.end };
                    count += 1;
                }
                if (source.options.actions) |actions| {
                    const call = actions.select orelse return error.NotSupported;
                    try call(actions.context, self.window, action.source, selections[0..count], primary);
                } else {
                    _ = try source.options.adapter.setSelections(selections[0..count], primary);
                    try source.options.adapter.revealCaret();
                }
            },
            5 => {
                if (source.options.actions) |actions| {
                    const call = actions.scroll orelse return error.NotSupported;
                    try call(actions.context, self.window, action.source, range, action.align_top != 0);
                } else {
                    const callback = source.options.scroll orelse return error.NotSupported;
                    try callback.call(callback.context, self.window, action.source, range, action.align_top != 0);
                }
            },
            else => return error.NotSupported,
        }
        var presentation_error: ?anyerror = null;
        if (source.options.changed) |callback| callback.call(callback.context, self.window, action.source, source.options.adapter) catch |err| {
            presentation_error = err;
        };
        const readers: [2]?d.Reader = .{ null, null };
        self.prepareTextInner(readers[0..self.count]) catch |err| {
            presentation_error = presentation_error orelse err;
        };
        self.window.invalidate();
        if (presentation_error) |err| return err;
    }
    fn report(self: *Bridge, err: anyerror) void {
        self.window.report(.{ .domain = .core, .operation = .resource_release, .err = err });
    }
};
fn rect(value: ui.Rect) n.Rect {
    return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
}

test {
    _ = model;
    _ = auxiliary;
}
test "common auxiliary capture never rounds a real edge inward" {
    try std.testing.expectEqual(@as(f32, 16777218), try Bridge.outwardExtent(16777217));
    try std.testing.expectEqual(@as(f32, 24), try Bridge.outwardExtent(24));
    try std.testing.expectError(error.InvalidGeometry, Bridge.outwardExtent(-1));
    try std.testing.expectError(error.InvalidGeometry, Bridge.outwardExtent(std.math.inf(f64)));
}
test "affine auxiliary storage is explicit optional storage" {
    std.debug.print("affine controls host costs: Bridge={d} MappingState={d} AuxiliaryState={d} AuxiliaryMapping={d}; transient Publication={d} AuxAction={d} AuxAccepted={d}\n", .{ @sizeOf(Bridge), @sizeOf(MappingState), @sizeOf(AuxiliaryState), @sizeOf(AuxiliaryMapping), @sizeOf(n.Publication), @sizeOf(n.AuxAction), @sizeOf(n.AuxAccepted) });
}
