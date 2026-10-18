const std = @import("std");
const caret_query = @import("caret.zig");
const command_types = @import("commands.zig");
pub const Command = command_types.Command;
pub const CommandOutcome = command_types.Outcome;
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const requests = @import("requests.zig");
const ix = @import("index.zig");
const readonly = @import("view.zig");
const accounting = @import("budget.zig");
const unified_index = @import("unified_index.zig");
const t = @import("ziggurat_text_layout");
const intraline = @import("intraline.zig");
const context = @import("context_index.zig");
const coordinates = @import("coordinates.zig");
pub const ContextOptions = context.Options;
pub const ContextKey = struct { serial: u64, id: u64 };
pub const ContextRegion = struct { key: ContextKey, collapsed: bool, a: @import("ziggurat_document_diff").LineRange, b: @import("ziggurat_document_diff").LineRange, headers: [2]?ui.Rect };
pub const Mode = enum { split, unified };
pub const Side = readonly.Side;
pub const Parameters = readonly.Parameters;
pub const Colors = readonly.Colors;
pub const Direction = readonly.Direction;
pub const Limits = struct { rows: usize = 262144, index_bytes: usize = 16 * 1024 * 1024, bytes: usize = 128 * 1024 * 1024, visible_rows: usize = 96, plan_entries: usize = 8192, revert_bytes: usize = 1024 * 1024, intraline_rects: usize = 1024 };
const max_rows = 96;
const canonical_shift = 26;
const canonical_units: f64 = 4294967296;
test "presentation epoch exhaustion preserves prior presentation authorization" {
    var value: State = .{ .budget = undefined, .owner = std.Thread.getCurrentId(), .inbox = undefined, .adapters = undefined, .window = undefined, .limits = .{}, .mode = .split, .presentation_epoch = std.math.maxInt(u64), .required = false };
    try std.testing.expectError(error.IdExhausted, value.prepare(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, .{}));
    try std.testing.expect(!value.required and value.presentation_epoch == std.math.maxInt(u64));
}
test "coordinator client pins reject overflow and survive an active callback" {
    var value: State = .{ .budget = undefined, .owner = std.Thread.getCurrentId(), .inbox = undefined, .adapters = undefined, .window = undefined, .limits = .{}, .mode = .split, .clients = std.math.maxInt(u32) };
    const view: *View = @ptrCast(&value);
    try std.testing.expectError(error.CapacityExceeded, view.retainClient());
    try std.testing.expectEqual(std.math.maxInt(u32), value.clients);
    value.clients = 1;
    value.busy = true;
    try view.releaseClient();
    try std.testing.expectEqual(@as(u32, 0), value.clients);
    try std.testing.expectError(error.Busy, view.close());
    value.busy = false;
    try std.testing.expectError(error.InvalidClient, view.releaseClient());
}
test "source acquisition exhaustion precedes binding or other focus work" {
    var value: State = .{ .budget = undefined, .owner = std.Thread.getCurrentId(), .inbox = undefined, .adapters = undefined, .window = undefined, .limits = .{}, .mode = .split, .acquisition_generation = std.math.maxInt(u64), .last_active = .a, .focused = .a };
    try std.testing.expectError(error.IdExhausted, value.focus(.b));
    try std.testing.expectEqual(Side.a, value.last_active);
    try std.testing.expectEqual(@as(?Side, .a), value.focused);
    try std.testing.expectEqual(std.math.maxInt(u64), value.acquisition_generation);
}
const Font = struct {
    options: @FieldType(Parameters, "font") = .{},
    family: [255]u8 = undefined,
    locale: [127]u8 = undefined,
    family_len: usize = 0,
    locale_len: usize = 0,
    fn set(self: *Font, value: @FieldType(Parameters, "font")) void {
        self.options = value;
        self.options.family = "";
        self.options.locale = "";
        self.family_len = value.family.len;
        self.locale_len = value.locale.len;
        @memcpy(self.family[0..self.family_len], value.family);
        @memcpy(self.locale[0..self.locale_len], value.locale);
    }
    fn get(self: *const Font) @FieldType(Parameters, "font") {
        var value = self.options;
        value.family = self.family[0..self.family_len];
        value.locale = self.locale[0..self.locale_len];
        return value;
    }
};
const Anchor = struct { row: usize = 0, intra: u128 = 0 };
pub const Row = struct { index: usize, a: ?usize, b: ?usize, hunk: ?usize, y: f32, height: f32 };
pub const IntralineMark = struct { side: Side, rect: ui.Rect };
pub const Info = struct { serial: u64, comparison_required: bool, composition_identity: bool, focused: ?Side, selected_hunk: ?usize, visible_rows: usize, total_rows: usize, anchor_row: usize, estimated_extent: f64, mode: Mode = .split };
/// Actual primary source caret, independent of layout, scroll and hunk choice.
/// Line and UTF-16 column are zero based. byte_offset is a UTF-8 byte boundary.
pub const CursorInfo = struct { side: Side, byte_offset: usize, line: usize, utf16_column: usize, revision: u64, text_version: u64 };
/// Derived value only. serial identifies the accepted comparison, not a queued
/// action capability; use the existing stamped action APIs for later mutation.
pub const HunkPosition = struct { serial: u64, side: Side, index: ?usize, inside: bool };
pub const Stats = struct { owned_bytes: usize, peak_bytes: usize, indexed_rows: usize, layout_updates: u64, intraline_rectangles: usize, intraline_queries: u64 };
pub const SourcePair = struct { window: z.Window, adapters: [2]*editing.Adapter, mode: Mode };
/// A source authorization stamp, not a document owner. The coordinator must
/// outlive every use. Acquisition generation distinguishes focus A-B-A, while
/// Document revisions distinguish equal-text edits, selection and IME changes.
pub const SourceStamp = struct {
    owner: *View,
    mode: Mode,
    side: Side,
    acquisition_generation: u64,
    revisions: [2]u64,
    text_versions: [2]u64,
    selection: d.Selection,
};
pub const SourceCapture = struct { stamp: SourceStamp, document: *d.Document };
/// Rows are copied to caller storage. Coordinates retain their original source.
pub const Presentation = struct {
    owner: *View,
    epoch: u64,
    comparison_serial: u64,
    mode: Mode,
    bounds: ui.Rect,
    columns: [2]ui.Rect,
    revisions: [2]u64,
    text_versions: [2]u64,
    view_versions: [2]u64,
    projection_versions: [2]u64,
    projected: bool,
    composing: bool,
    rows: []const Row,
};
pub const SelectionOutcome = struct { changed: bool, presentation_error: ?anyerror = null };
pub const RevertOutcome = struct { changed: bool, index_required: bool, presentation_error: ?anyerror = null };
const Marks = struct { serial: u64 = 0, versions: [2]u64 = @splat(0), storage: []IntralineMark = &.{}, count: usize = 0 };
const MarkBuffers = struct {
    storage: []IntralineMark = &.{},
    scratch: []t.Rect = &.{},
    fn close(self: *MarkBuffers, allocator: std.mem.Allocator) void {
        const previous = self.*;
        self.* = .{};
        allocator.free(previous.storage);
        allocator.free(previous.scratch);
    }
};
const Snapshot = struct { bounds: ui.Rect, columns: [2]ui.Rect, parameters: Parameters, font: Font = .{}, revisions: [2]u64, view_versions: [2]u64, serial: u64, projected: bool, composing: bool, rows: [max_rows]Row = undefined, count: usize = 0 };

/// Explicit affine companion borrow. Close the native publisher before close;
/// Context storage covers the installed Space through native client unbinding.
pub const CoordinateBinding = opaque {
    fn data(self: *CoordinateBinding) !*CoordinateState {
        const value: *CoordinateState = @ptrCast(@alignCast(self));
        if (value.owner.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (value.owner.busy) return error.Busy;
        if (value.owner.coordinates != value) return error.StaleSpace;
        if (value.active != 0) return error.Busy;
        return value;
    }
    pub const Scope = struct {
        value: ?*CoordinateState,
        pub fn end(self: *Scope) void {
            const value = self.value orelse return;
            self.value = null;
            std.debug.assert(value.active == 1);
            value.active = 0;
        }
    };
    /// Cover native publisher construction/destruction, including the final
    /// allocator callback after that publisher has withdrawn its own borrow.
    pub fn pin(self: *CoordinateBinding) !Scope {
        const value = try self.data();
        value.active = 1;
        return .{ .value = value };
    }
    pub fn publication(self: *CoordinateBinding) !*editing.PresentationLease {
        return &(try self.data()).value.lease;
    }
    pub fn attachContext(self: *CoordinateBinding, host: *ui.Context) !void {
        const value = try self.data();
        if (host.window == null or !std.meta.eql(host.window.?, value.owner.window)) return error.ForeignWindow;
        if (value.value.context != null) return error.AlreadyAttached;
        value.value.context = host;
    }
    /// A real accepted capture of this binding's configured ID, never a pending
    /// Frame, another front, or another body's capture, authorizes native input.
    pub fn setCommittedSpace(self: *CoordinateBinding, token: ui.SpaceToken) !void {
        const value = try self.data();
        const owner = value.owner;
        const scope = owner.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        owner.busy = true;
        defer owner.busy = false;
        const generation = (try value.value.lease.snapshot()).generation;
        const binding = try value.value.candidateSpace(owner.window, token);
        if (owner.focused) |side| if (try owner.adapters[@intFromEnum(side)].isBound()) try owner.adapters[@intFromEnum(side)].setCommittedSpace(token);
        if ((try value.value.lease.snapshot()).generation != generation) return error.StalePresentation;
        if (owner.window.isClosed()) return error.Closed;
        value.value.space = binding;
    }
    /// Pair this with both native geometry records inside exactly the same
    /// Frame scope. Only fixed POD metadata and the existing Space table change.
    pub fn record(self: *CoordinateBinding, frame: *ui.Frame, epoch: u64) !void {
        const value = try self.data();
        const owner = value.owner;
        try owner.validatePresentation(epoch);
        if (frame.context != value.value.context) return error.ForeignFrame;
        const snapshot = owner.snapshot.?;
        try frame.captureSpace(value.value.id, snapshot.bounds);
        var mapping: ui.CoordinateMapping = undefined;
        try frame.coordinateMapping(snapshot.bounds, &mapping);
        const generation = mapping.space_generation orelse return error.TransformsRequired;
        value.value.record(.{ .stamp = .{ .publication = epoch, .source = mapping.source, .candidate = mapping.candidate, .space_epoch = mapping.epoch, .space_generation = generation }, .bounds = snapshot.bounds, .columns = snapshot.columns, .scale = snapshot.parameters.scale });
    }
    pub fn syncCaret(self: *CoordinateBinding) !void {
        const value = try self.data();
        const scope = value.owner.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.owner.busy = true;
        defer value.owner.busy = false;
        try value.owner.syncCaret();
    }
    pub fn check(self: *CoordinateBinding) !u64 {
        const value = try self.data();
        return (try value.owner.coordinateGeneration()).?;
    }
    /// Revoke first, then cancel the real native owner. A deferred unbind keeps
    /// both the allocation and publisher borrow alive for a later explicit call.
    pub fn withdraw(self: *CoordinateBinding) !void {
        const value = try self.data();
        const owner = value.owner;
        const scope = owner.window.app.beginTeardownCallback();
        defer scope.end();
        owner.busy = true;
        defer owner.busy = false;
        value.value.space = null;
        // Counter exhaustion has already withdrawn every accepted stamp. It
        // forbids future publication, but must not strand teardown ownership.
        _ = value.value.lease.withdraw() catch |err| switch (err) {
            error.IdExhausted => 0,
        };
        owner.focused = null;
        for (owner.adapters) |adapter| try adapter.unbind();
    }
    pub fn close(self: *CoordinateBinding) !void {
        const value = try self.data();
        const owner = value.owner;
        if (value.value.lease.hasPublisher()) return error.PublisherAttached;
        for (owner.adapters) |adapter| if (try adapter.isBound()) return error.UnbindPending;
        if (value.value.space != null) return error.SpaceAttached;
        owner.busy = true;
        defer owner.busy = false;
        owner.coordinates = null;
        owner.budget.allocator().destroy(value);
    }
};
const CoordinateState = struct { owner: *State, value: coordinates.State, active: u1 = 0 };

/// Editable split comparison. Document/Adapter keep all text, selection, undo,
/// IME and visual input state; this owner derives only row alignment and focus.
pub const View = opaque {
    fn state(self: *const View) !*State {
        const value: *State = @ptrCast(@alignCast(@constCast(self)));
        if (value.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (value.busy) return error.Busy;
        return value;
    }
    pub fn create(allocator: std.mem.Allocator, inbox: *requests.Inbox, a: *editing.Adapter, b: *editing.Adapter, window: z.Window, limits: Limits) !*View {
        return createMode(allocator, inbox, a, b, window, limits, .split);
    }
    fn createMode(allocator: std.mem.Allocator, inbox: *requests.Inbox, a: *editing.Adapter, b: *editing.Adapter, window: z.Window, limits: Limits, mode: Mode) !*View {
        if (limits.rows == 0 or limits.rows > 2097152 or limits.index_bytes == 0 or limits.index_bytes > 1024 * 1024 * 1024 or limits.bytes < @sizeOf(State) or limits.bytes > 1024 * 1024 * 1024 or limits.visible_rows == 0 or limits.visible_rows > max_rows or limits.plan_entries == 0 or limits.plan_entries > 65536 or limits.revert_bytes == 0 or limits.revert_bytes > 64 * 1024 * 1024 or limits.intraline_rects == 0 or limits.intraline_rects > 8192) return error.InvalidLimits;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (try a.sourceDocument() != inbox.pair.a or try b.sourceDocument() != inbox.pair.b) return error.ForeignDocument;
        if (a == b) return error.SameAdapter;
        if (try a.isBound() or try b.isBound()) return error.ClientAttached;
        if (try a.projectionPlan() != null or try b.projectionPlan() != null) return error.ProjectionAttached;
        try inbox.retainClient();
        errdefer {
            const borrow = inbox.borrowForTeardown() catch unreachable;
            borrow.releaseClient() catch unreachable;
            borrow.end();
        }
        try a.retainClient();
        errdefer a.releaseClient() catch unreachable;
        try b.retainClient();
        errdefer b.releaseClient() catch unreachable;
        const value = try allocator.create(State);
        errdefer allocator.destroy(value);
        if (window.isClosed()) return error.Closed;
        value.* = .{ .budget = .{ .source = allocator, .limit = limits.bytes, .live = @sizeOf(State), .peak = @sizeOf(State) }, .owner = std.Thread.getCurrentId(), .inbox = inbox, .adapters = .{ a, b }, .window = window, .limits = limits, .mode = mode };
        value.observers[0] = try a.observeNativeChanges(.{ .context = value, .call = State.nativeChanged, .validate = State.nativeAuthority });
        errdefer _ = a.clearNativeObserver(value.observers[0]) catch unreachable;
        value.observers[1] = try b.observeNativeChanges(.{ .context = value, .call = State.nativeChanged, .validate = State.nativeAuthority });
        return @ptrCast(value);
    }
    pub fn close(self: *View) !void {
        const value = try self.state();
        if (value.clients != 0) return error.ClientsAlive;
        if (value.coordinates != null) return error.CoordinatesAttached;
        const scope = value.window.app.beginTeardownCallback();
        defer scope.end();
        for (value.adapters) |adapter| try adapter.ensureUnused();
        const borrow = try value.inbox.borrowForTeardown();
        defer borrow.end();
        value.busy = true;
        errdefer value.busy = false;
        if (value.focused) |side| try value.adapters[@intFromEnum(side)].unbind();
        for (value.adapters, value.observers) |adapter, token| _ = try adapter.clearNativeObserver(token);
        for (value.adapters, value.plans) |adapter, plan| if (plan != null and try adapter.projectionPlan() == plan) try adapter.setProjection(null);
        for (value.adapters, &value.fold_tokens) |adapter, *token| if (token.*) |owned| {
            std.debug.assert(try adapter.releaseFolds(owned));
            token.* = null;
        };
        if (value.context_index) |*index| index.close();
        for (value.plans) |plan| if (plan) |owned| owned.close() catch unreachable;
        if (value.index) |*index| index.close();
        value.budget.allocator().free(value.marks.storage);
        for (value.adapters) |adapter| adapter.releaseClient() catch unreachable;
        borrow.releaseClient() catch unreachable;
        std.debug.assert(value.budget.live == @sizeOf(State));
        const allocator = value.budget.source;
        allocator.destroy(value);
    }
    pub fn retainClient(self: *View) !void {
        const value = try self.state();
        if (value.clients == std.math.maxInt(u32)) return error.CapacityExceeded;
        value.clients += 1;
    }
    pub fn releaseClient(self: *View) !void {
        // Releasing a retained companion is safe while preparation is busy;
        // close itself remains Busy and cannot free the active coordinator.
        const value: *State = @ptrCast(@alignCast(self));
        if (value.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (value.clients == 0) return error.InvalidClient;
        value.clients -= 1;
    }
    pub fn sourcePair(self: *View) !SourcePair {
        const value = try self.state();
        return .{ .window = value.window, .adapters = value.adapters, .mode = value.mode };
    }
    /// Opt in while neither source owns a native client. One explicit affine
    /// companion owns the coordinate policy until its publisher has detached.
    pub fn acquireCoordinates(self: *View, space_id: u64) !*CoordinateBinding {
        const value = try self.state();
        if (value.coordinates != null) return error.CoordinatesAttached;
        if (space_id == 0) return error.InvalidSpace;
        for (value.adapters) |adapter| if (try adapter.isBound()) return error.ClientAttached;
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        const candidate = try value.budget.allocator().create(CoordinateState);
        errdefer value.budget.allocator().destroy(candidate);
        if (value.window.isClosed()) return error.Closed;
        candidate.* = .{ .owner = value, .value = .{ .id = space_id } };
        value.coordinates = candidate;
        value.coordinate_policy = true;
        return @ptrCast(candidate);
    }
    /// Constant-size owner queries. No shaping, full-text scan or allocation.
    pub fn captureSource(self: *View) !SourceCapture {
        const value = try self.state();
        const stamp = try value.sourceStamp();
        return .{ .stamp = stamp, .document = value.documents()[@intFromEnum(stamp.side)] };
    }
    pub fn validateSource(self: *View, stamp: SourceStamp) !void {
        try (try self.state()).validateSource(stamp);
    }
    pub fn copyPresentation(self: *View, output: []Row) !Presentation {
        const value = try self.state();
        try value.live();
        try value.validatePresentation(value.presentation_epoch);
        const prepared = value.snapshot orelse return error.LayoutRequired;
        const snapshot = try value.current(prepared.bounds, prepared.parameters.scale);
        if (output.len < snapshot.count) return error.CapacityExceeded;
        const versions = [2]u64{ try value.documents()[0].committedTextVersion(), try value.documents()[1].committedTextVersion() };
        const projections = [2]u64{ try value.adapters[0].projectionVersion(), try value.adapters[1].projectionVersion() };
        @memcpy(output[0..snapshot.count], snapshot.rows[0..snapshot.count]);
        return .{ .owner = self, .epoch = value.presentation_epoch, .comparison_serial = snapshot.serial, .mode = value.mode, .bounds = snapshot.bounds, .columns = snapshot.columns, .revisions = snapshot.revisions, .text_versions = versions, .view_versions = snapshot.view_versions, .projection_versions = projections, .projected = snapshot.projected, .composing = snapshot.composing, .rows = output[0..snapshot.count] };
    }
    pub fn validatePresentation(self: *View, epoch: u64) !void {
        try (try self.state()).validatePresentation(epoch);
    }
    pub fn focusPresented(self: *View, epoch: u64, side: Side) !void {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        try value.validateAction(epoch);
        value.busy = true;
        defer value.busy = false;
        try value.focus(side);
        try value.window.perform(.focus);
    }
    /// Revoke the coordinator's sole retained native client before a control
    /// acquires focus. Failure never restores a client already revoked.
    pub fn blurPresented(self: *View, epoch: u64) !void {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        try value.validateAction(epoch);
        value.busy = true;
        defer value.busy = false;
        const previous = value.focused orelse return;
        value.focused = null;
        try value.adapters[@intFromEnum(previous)].unbind();
        try value.validateAction(epoch);
    }
    /// A successful text edit is never reported as a retryable layout error.
    pub fn revertPresented(self: *View, epoch: u64, hunk: usize, direction: Direction) !RevertOutcome {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        try value.validateAction(epoch);
        value.busy = true;
        defer value.busy = false;
        value.action_epoch = epoch;
        defer value.action_epoch = null;
        const result = try value.revert(hunk, direction);
        const old = value.snapshot.?;
        var parameters = old.parameters;
        parameters.font = old.font.get();
        value.prepare(old.bounds, parameters) catch |err| return .{ .changed = result.changed, .index_required = result.index_required, .presentation_error = value.budget.normalize(err) };
        return .{ .changed = result.changed, .index_required = result.index_required };
    }
    pub fn setContextPresented(self: *View, epoch: u64, key: ContextKey, collapsed: bool) !SelectionOutcome {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        try value.validateAction(epoch);
        // Carry the entering accepted coordinate generation through planner
        // build/complete and the final guard in every paired projection branch.
        value.input_coordinate = try value.coordinateGeneration();
        defer value.input_coordinate = null;
        if (key.serial != value.snapshot.?.serial) return error.StaleContext;
        value.busy = true;
        defer value.busy = false;
        value.action_epoch = epoch;
        defer value.action_epoch = null;
        const mapping = if (value.context_index) |*index| index else return error.ContextDisabled;
        const at = mapping.find(key.id) orelse return error.FoldNotFound;
        if (mapping.regions[at].collapsed == collapsed) return .{ .changed = false };
        const changed = value.changeContext(key, collapsed, null) catch |err| {
            value.required = true;
            // Paired fold/layout ownership may already have published before
            // old-resource destruction or caret presentation failed.
            if (value.context_index) |*current| if (current.find(key.id)) |index| {
                if (value.context_serial == key.serial and current.regions[index].collapsed == collapsed) return .{ .changed = true, .presentation_error = value.budget.normalize(err) };
            };
            return value.budget.normalize(err);
        };
        return .{ .changed = changed };
    }
    /// A post-commit layout failure is an outcome, never a retryable mutation.
    pub fn selectPresented(self: *View, epoch: u64, side: Side, selections: []const d.Selection, primary: usize) !SelectionOutcome {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        try value.validateAction(epoch);
        if (value.mode == .unified and side != .b) return error.ReadOnlySource;
        if (selections.len == 0 or selections.len > 64 or primary >= selections.len) return error.InvalidSelections;
        value.busy = true;
        defer value.busy = false;
        return value.selectPresented(side, selections, primary);
    }
    pub fn scrollPresented(self: *View, epoch: u64, side: Side, range: d.Range, align_top: bool) !void {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        try value.validateAction(epoch);
        if (value.mode == .unified and side != .b) return error.ReadOnlySource;
        const document = value.documents()[@intFromEnum(side)];
        _ = try document.utf16Offset(range.start);
        _ = try document.utf16Offset(range.end);
        if (range.start > range.end) return error.InvalidRange;
        value.busy = true;
        defer value.busy = false;
        try value.reveal(side, if (align_top) range.start else range.end);
        if (!align_top) {
            const snapshot = value.snapshot.?;
            if (value.index) |*index| {
                const line = try document.lineAt(range.end);
                if (sourceRow(index, @intFromEnum(side), line)) |row| {
                    const end = @as(u128, index.prefix(row + 1)) << canonical_shift;
                    const height: u128 = @intFromFloat(@ceil(@as(f64, snapshot.bounds.height) * canonical_units));
                    const target = end -| height;
                    const located = index.locate(@intCast(target >> canonical_shift));
                    value.anchor = .{ .row = located.row, .intra = target - (@as(u128, index.prefix(located.row)) << canonical_shift) };
                    var parameters = snapshot.parameters;
                    parameters.font = snapshot.font.get();
                    try value.prepare(snapshot.bounds, parameters);
                }
            }
        }
        value.window.invalidate();
    }
    pub fn prepare(self: *View, bounds: ui.Rect, parameters: Parameters) !void {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        value.prepare(bounds, parameters) catch |err| {
            value.required = true;
            return value.budget.normalize(err);
        };
    }
    pub fn draw(self: *View, frame: *ui.Frame, bounds: ui.Rect, colors: Colors) anyerror!void {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        errdefer |err| frame.failure = frame.failure orelse err;
        const snapshot = try value.current(bounds, frame.size.scale);
        try frame.pushClip(bounds);
        defer frame.popClip() catch |err| {
            frame.failure = frame.failure orelse err;
        };
        frame.rect(bounds, colors.background);
        if (snapshot.projected) for (snapshot.rows[0..snapshot.count]) |row| if (row.hunk != null) {
            if (value.mode == .unified) {
                const rectangle = ui.layout.intersect(bounds, .{ .x = bounds.x, .y = bounds.y + row.y, .width = bounds.width, .height = row.height });
                frame.rect(rectangle, if (row.b == null) colors.deleted else colors.added);
                if (row.hunk == value.selected) frame.rect(.{ .x = rectangle.x, .y = rectangle.y, .width = @min(3, rectangle.width), .height = rectangle.height }, colors.selected);
            } else for (snapshot.columns, 0..) |column, side| {
                const rectangle = ui.layout.intersect(column, .{ .x = column.x, .y = column.y + row.y, .width = column.width, .height = row.height });
                const source = if (side == 0) row.a else row.b;
                frame.rect(rectangle, if (source == null) colors.blank else if (side == 0) colors.deleted else colors.added);
                if (row.hunk == value.selected) frame.rect(.{ .x = rectangle.x, .y = rectangle.y, .width = @min(3, rectangle.width), .height = rectangle.height }, colors.selected);
            }
        };
        for (value.marks.storage[0..value.marks.count]) |mark| frame.rect(mark.rect, if (mark.side == .a) colors.deleted_detail else colors.added_detail);
        if (value.mode == .unified) {
            try value.adapters[1].draw(frame, snapshot.columns[1], .{ .text = colors.text });
            if (value.window.isClosed()) return error.Closed;
            if (snapshot.projected) {
                var ghosts: [max_rows]usize = undefined;
                var count: usize = 0;
                for (snapshot.rows[0..snapshot.count]) |row| if (row.b == null) if (row.a) |line| {
                    ghosts[count] = line;
                    count += 1;
                };
                if (count != 0) try value.adapters[0].drawParagraphs(frame, snapshot.columns[0], ghosts[0..count], colors.text);
                if (value.window.isClosed()) return error.Closed;
            }
        } else for (value.adapters, snapshot.columns) |adapter, column| {
            try adapter.draw(frame, column, .{ .text = colors.text });
            if (value.window.isClosed()) return error.Closed;
        }
        if (snapshot.projected and value.context_index != null) {
            var headers: [max_rows]ContextRegion = undefined;
            for (try value.contextRegions(&headers)) |region| for (region.headers) |header| if (header) |rectangle| {
                frame.rect(rectangle, colors.header);
                const middle = rectangle.y + rectangle.height * 0.5;
                frame.rect(.{ .x = rectangle.x + 2, .y = middle, .width = rectangle.width - 4, .height = 1 }, 0x4c596d);
                if (region.collapsed) frame.rect(.{ .x = rectangle.x + rectangle.width * 0.5, .y = middle - 3, .width = 1, .height = 7 }, 0x4c596d);
            };
        }
        if (frame.failure) |err| return @as(anyerror!void, err);
    }
    pub fn info(self: *View) !Info {
        const value = try self.state();
        const snapshot = value.snapshot orelse return error.LayoutRequired;
        _ = try value.current(snapshot.bounds, snapshot.parameters.scale);
        return .{ .serial = snapshot.serial, .comparison_required = !snapshot.projected and !snapshot.composing, .composition_identity = snapshot.composing, .focused = value.focused, .selected_hunk = if (snapshot.projected) value.selected else null, .visible_rows = snapshot.count, .total_rows = if (value.index) |*index| index.heights.len else 0, .anchor_row = value.anchor.row, .estimated_extent = if (value.index) |*index| ix.dip(index.prefix(index.heights.len)) else 0, .mode = value.mode };
    }
    /// Last successful native editor takeover; defaults to B, always B in a
    /// unified view. Losing focus to a toolbar does not change this source.
    pub fn activeSide(self: *View) !Side {
        const value = try self.state();
        try value.queryLive();
        return value.activeSide();
    }
    /// No prepare, native query, shaping or allocation. A stale comparison does
    /// not prevent querying the current Document's actual primary caret.
    pub fn cursor(self: *View) !CursorInfo {
        return (try self.state()).cursorInfo();
    }
    pub fn currentHunk(self: *View) !HunkPosition {
        const value = try self.state();
        const position = try value.cursorInfo();
        const borrow = try value.inbox.borrow();
        defer borrow.end();
        const display = try borrow.display() orelse return error.ComparisonRequired;
        const document = value.documents()[@intFromEnum(position.side)];
        const located = caret_query.locate(display.result.hunks, position.line, .{ .side_a = position.side == .a, .bytes = try document.byteLength(), .last_line = (try document.lineCount()) - 1 });
        return .{ .serial = display.serial, .side = position.side, .index = located.index, .inside = located.inside };
    }
    /// Explicit owner/menu command on the last active source. This does not
    /// synthesize a key, acquire native focus, or mutate manual hunk selection.
    /// Scratch holds twice the original canonical Document selection count.
    pub fn run(self: *View, command: Command, selection_scratch: []d.Selection) !CommandOutcome {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        return value.run(command, selection_scratch);
    }
    /// Validate the captured source under the same coordinator gate that spans
    /// command preparation, final Document guard and presentation cleanup.
    pub fn runFromSource(self: *View, stamp: SourceStamp, command: Command, selection_scratch: []d.Selection) !CommandOutcome {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        try value.validateSource(stamp);
        return value.run(command, selection_scratch);
    }
    pub fn stats(self: *const View) !Stats {
        const value = try self.state();
        return .{ .owned_bytes = value.budget.live, .peak_bytes = value.budget.peak, .indexed_rows = if (value.index) |*index| index.heights.len else 0, .layout_updates = value.layout_updates, .intraline_rectangles = value.marks.count, .intraline_queries = value.intraline_queries };
    }
    /// Prepared, clipped grapheme rectangles. No diff, shaping or allocation.
    pub fn intralineRects(self: *View, output: []IntralineMark) ![]const IntralineMark {
        const value = try self.state();
        const snapshot = value.snapshot orelse return error.LayoutRequired;
        _ = try value.current(snapshot.bounds, snapshot.parameters.scale);
        if (output.len < value.marks.count) return error.CapacityExceeded;
        @memcpy(output[0..value.marks.count], value.marks.storage[0..value.marks.count]);
        return output[0..value.marks.count];
    }
    /// Borrowed prepared row metadata, copied into caller storage.
    pub fn rowInfo(self: *View, output: []Row) ![]const Row {
        const value = try self.state();
        const prepared = value.snapshot orelse return error.LayoutRequired;
        const snapshot = try value.current(prepared.bounds, prepared.parameters.scale);
        if (output.len < snapshot.count) return error.CapacityExceeded;
        @memcpy(output[0..snapshot.count], snapshot.rows[0..snapshot.count]);
        return output[0..snapshot.count];
    }
    pub fn focus(self: *View, side: Side) !void {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        try value.focus(side);
    }
    /// Explicit desired configuration; call prepare before drawing again.
    pub fn setContext(self: *View, options: ?ContextOptions) !void {
        const value = try self.state();
        if (options) |settings| try context.validateOptions(settings);
        if (std.meta.eql(value.context_options, options)) return;
        if (value.context_generation == std.math.maxInt(u64)) return error.IdExhausted;
        value.context_options = options;
        value.context_generation += 1;
        value.required = true;
    }
    pub fn contextRegions(self: *View, output: []ContextRegion) ![]const ContextRegion {
        return (try self.state()).contextRegions(output);
    }
    pub fn setContextCollapsed(self: *View, key: ContextKey, collapsed: bool) !bool {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        return value.changeContext(key, collapsed, null) catch |err| {
            value.required = true;
            return value.budget.normalize(err);
        };
    }
    /// Expand context around an original source position, without changing its
    /// Document selection. The host can then select through that sole Adapter.
    pub fn reveal(self: *View, side: Side, position: usize) !void {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        value.reveal(side, position) catch |err| {
            value.required = true;
            return value.budget.normalize(err);
        };
    }
    pub fn scrollBy(self: *View, delta: f32) !bool {
        return (try self.state()).scroll(delta);
    }
    pub fn navigate(self: *View, forward: bool) !bool {
        return (try self.state()).navigate(forward);
    }
    pub fn revert(self: *View, hunk: usize, direction: Direction) !editing.EditResult {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        return value.revert(hunk, direction);
    }
    pub fn handleEvent(self: *View, event: z.Event, bounds: ui.Rect, parameters: Parameters) !bool {
        const value = try self.state();
        const scope = value.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        defer value.input_coordinate = null;
        if (value.coordinate_policy and value.coordinates == null and event != .cancel_input and !(event == .focus and !event.focus)) return error.GeometryRequired;
        const mapped = if (value.coordinates) |space| mapped: {
            if (event == .cancel_input or (event == .focus and !event.focus)) break :mapped event;
            const snapshot = value.snapshot orelse return error.LayoutRequired;
            const accepted = try space.value.resolve(value.window, snapshot.columns, parameters.scale);
            value.input_coordinate = accepted.generation;
            switch (event) {
                .pointer_down => |pointer| if (!try accepted.token.contains(pointer.position)) return false,
                .wheel => |wheel| if (!try accepted.token.contains(wheel.position)) return false,
                else => {},
            }
            break :mapped try accepted.token.mapEvent(event, .{});
        } else event;
        return value.event(mapped, bounds, parameters) catch |err| {
            value.required = true;
            return value.budget.normalize(err);
        };
    }
};

/// Unified presentation has exactly one editable source: modified Document B.
/// Removed A paragraphs are read-only ghost display records without B offsets.
pub const Unified = opaque {
    fn shared(self: *Unified) *View {
        return @ptrCast(self);
    }
    pub fn coordinator(self: *Unified) *View {
        return self.shared();
    }
    pub fn create(allocator: std.mem.Allocator, inbox: *requests.Inbox, a: *editing.Adapter, b: *editing.Adapter, window: z.Window, limits: Limits) !*Unified {
        return @ptrCast(try View.createMode(allocator, inbox, a, b, window, limits, .unified));
    }
    pub fn close(self: *Unified) !void {
        try self.shared().close();
    }
    pub fn prepare(self: *Unified, bounds: ui.Rect, parameters: Parameters) !void {
        try self.shared().prepare(bounds, parameters);
    }
    pub fn draw(self: *Unified, frame: *ui.Frame, bounds: ui.Rect, colors: Colors) anyerror!void {
        try self.shared().draw(frame, bounds, colors);
    }
    pub fn info(self: *Unified) !Info {
        return self.shared().info();
    }
    pub fn activeSide(self: *Unified) !Side {
        return self.shared().activeSide();
    }
    pub fn cursor(self: *Unified) !CursorInfo {
        return self.shared().cursor();
    }
    pub fn currentHunk(self: *Unified) !HunkPosition {
        return self.shared().currentHunk();
    }
    pub fn run(self: *Unified, command: Command, selection_scratch: []d.Selection) !CommandOutcome {
        return self.shared().run(command, selection_scratch);
    }
    pub fn stats(self: *Unified) !Stats {
        return self.shared().stats();
    }
    pub fn rowInfo(self: *Unified, output: []Row) ![]const Row {
        return self.shared().rowInfo(output);
    }
    pub fn focus(self: *Unified) !void {
        try self.shared().focus(.b);
    }
    pub fn scrollBy(self: *Unified, delta: f32) !bool {
        return self.shared().scrollBy(delta);
    }
    pub fn navigate(self: *Unified, forward: bool) !bool {
        return self.shared().navigate(forward);
    }
    pub fn revert(self: *Unified, hunk: usize) !editing.EditResult {
        return self.shared().revert(hunk, .a_to_b);
    }
    pub fn handleEvent(self: *Unified, event: z.Event, bounds: ui.Rect, parameters: Parameters) !bool {
        return self.shared().handleEvent(event, bounds, parameters);
    }
    pub fn intralineRects(self: *Unified, output: []IntralineMark) ![]const IntralineMark {
        return self.shared().intralineRects(output);
    }
    pub fn setContext(self: *Unified, options: ?ContextOptions) !void {
        return self.shared().setContext(options);
    }
    pub fn contextRegions(self: *Unified, output: []ContextRegion) ![]const ContextRegion {
        return self.shared().contextRegions(output);
    }
    pub fn setContextCollapsed(self: *Unified, key: ContextKey, collapsed: bool) !bool {
        return self.shared().setContextCollapsed(key, collapsed);
    }
    pub fn reveal(self: *Unified, position: usize) !void {
        return self.shared().reveal(.b, position);
    }
};

const State = struct {
    budget: accounting.Budget,
    owner: std.Thread.Id,
    inbox: *requests.Inbox,
    adapters: [2]*editing.Adapter,
    window: z.Window,
    limits: Limits,
    mode: Mode,
    busy: bool = false,
    action_epoch: ?u64 = null,
    // Only the current input call borrows this accepted coordinate authority.
    // It imposes no composition or Document-revision restriction.
    input_coordinate: ?u64 = null,
    clients: u32 = 0,
    coordinates: ?*CoordinateState = null,
    // Retired affine policy never silently falls back to window-DIP input.
    // A later explicit coordinate binding may reauthorize this same View.
    coordinate_policy: bool = false,
    presentation_epoch: u64 = 0,
    required: bool = true,
    index: ?ix.Index = null,
    serial: u64 = 0,
    plans: [2]?*editing.ProjectionPlan = @splat(null),
    observers: [2]editing.NativeObserverToken = undefined,
    anchor: Anchor = .{},
    selected: ?usize = null,
    focused: ?Side = null,
    last_active: Side = .b,
    acquisition_generation: u64 = 1,
    snapshot: ?Snapshot = null,
    layout_updates: u64 = 0,
    marks: Marks = .{},
    intraline_queries: u64 = 0,
    context_options: ?ContextOptions = null,
    context_generation: u64 = 0,
    applied_context_generation: u64 = 0,
    context_index: ?context.Index = null,
    context_serial: u64 = 0,
    fold_tokens: [2]?editing.FoldToken = @splat(null),
    fold_versions: [2]u64 = @splat(0),
    pending_context: ?struct { key: ContextKey, collapsed: bool } = null,
    reveal_raw: ?usize = null,
    context_index_required: bool = false,
    context_active: bool = false,
    fn documents(self: *State) [2]*d.Document {
        return .{ self.inbox.pair.a, self.inbox.pair.b };
    }
    fn live(self: *State) !void {
        if (self.window.isClosed() or self.window.app.phase == .stopping or self.window.app.phase == .stopped) return error.Closed;
    }
    fn queryLive(self: *State) !void {
        try self.live();
        if (self.inbox.stopping) return error.Closed;
    }
    fn activeSide(self: *const State) Side {
        return if (self.mode == .unified) .b else self.last_active;
    }
    fn sourceStamp(self: *State) !SourceStamp {
        try self.queryLive();
        const documents_value = self.documents();
        for (documents_value) |document| if (try document.composition() != null) return error.CompositionActive;
        const window_state = try self.window.state();
        if (!window_state.enabled or window_state.modal_blocked) return error.Disabled;
        const side = self.activeSide();
        return .{
            .owner = @ptrCast(self),
            .mode = self.mode,
            .side = side,
            .acquisition_generation = self.acquisition_generation,
            .revisions = .{ try documents_value[0].version(), try documents_value[1].version() },
            .text_versions = .{ try documents_value[0].committedTextVersion(), try documents_value[1].committedTextVersion() },
            .selection = try documents_value[@intFromEnum(side)].selection(),
        };
    }
    fn validateSource(self: *State, stamp: SourceStamp) !void {
        if (stamp.owner != @as(*View, @ptrCast(self)) or stamp.mode != self.mode) return error.ForeignSource;
        const current_stamp = try self.sourceStamp();
        if (stamp.acquisition_generation != current_stamp.acquisition_generation or stamp.side != current_stamp.side) return error.StaleActiveSide;
        if (!std.meta.eql(stamp.revisions, current_stamp.revisions) or !std.meta.eql(stamp.text_versions, current_stamp.text_versions) or !std.meta.eql(stamp.selection, current_stamp.selection)) return error.StaleRevision;
    }
    fn cursorInfo(self: *State) !CursorInfo {
        try self.queryLive();
        for (self.documents()) |document| if (try document.composition() != null) return error.CompositionActive;
        const side = self.activeSide();
        const document = self.documents()[@intFromEnum(side)];
        const selected = try document.selection();
        const line = try document.lineAt(selected.caret);
        const range = try document.line(line);
        const column = (try document.utf16Offset(selected.caret)) - (try document.utf16Offset(range.start));
        return .{ .side = side, .byte_offset = selected.caret, .line = line, .utf16_column = column, .revision = try document.version(), .text_version = try document.committedTextVersion() };
    }
    const CommandGuard = struct {
        state: *State,
        side: Side,
        peer: *d.Document,
        peer_revision: u64,
        acquisition_generation: u64,
        fn validate(ptr: *anyopaque) !void {
            const guard: *@This() = @ptrCast(@alignCast(ptr));
            try guard.state.queryLive();
            if (guard.state.activeSide() != guard.side or guard.state.acquisition_generation != guard.acquisition_generation) return error.StaleActiveSide;
            if (try guard.peer.version() != guard.peer_revision) return error.StaleRevision;
            if (try guard.peer.composition() != null) return error.CompositionActive;
            const state = try guard.state.window.state();
            if (!state.enabled or state.modal_blocked) return error.Disabled;
        }
    };
    fn run(self: *State, command: Command, selection_scratch: []d.Selection) !CommandOutcome {
        try self.queryLive();
        for (self.documents()) |document| if (try document.composition() != null) return error.CompositionActive;
        const side = self.activeSide();
        const at = @intFromEnum(side);
        const revisions = [2]u64{ try self.documents()[0].version(), try self.documents()[1].version() };
        var validation: CommandGuard = .{ .state = self, .side = side, .peer = self.documents()[1 - at], .peer_revision = revisions[1 - at], .acquisition_generation = self.acquisition_generation };
        try CommandGuard.validate(&validation);
        const count = try self.documents()[at].selectionCount();
        if (selection_scratch.len < (std.math.mul(usize, count, 2) catch return error.SelectionCapacityExceeded)) return error.SelectionCapacityExceeded;
        var parameters: Parameters = .{};
        var font: Font = .{};
        const bounds = if (self.snapshot) |snapshot| blk: {
            parameters = snapshot.parameters;
            font = snapshot.font;
            parameters.font = font.get();
            if (self.current(snapshot.bounds, snapshot.parameters.scale)) |_| {} else |_| {
                try self.prepare(snapshot.bounds, parameters);
            }
            break :blk snapshot.bounds;
        } else null;
        const target: ?d.Selection = switch (command) {
            .set_selection => |selected| selected,
            .select_all => .{ .anchor = 0, .caret = try self.documents()[at].byteLength() },
            else => null,
        };
        if (target) |selected| {
            if (bounds != null) try self.prepareSelection(side, &.{selected}, 0, revisions);
        }
        const changed = try self.adapters[at].runCommand(command, .{ .expected_revision = revisions[at], .context = &validation, .validate = CommandGuard.validate }, selection_scratch);
        var outcome = CommandOutcome.from(side, changed);
        self.required = true;
        if (outcome.presentation_error != null) return self.finishCommand(outcome, &validation, revisions[at]);
        if (bounds) |rectangle| {
            self.prepare(rectangle, parameters) catch |err| {
                outcome.presentation_error = self.budget.normalize(err);
                return self.finishCommand(outcome, &validation, revisions[at]);
            };
            self.syncCaret() catch |err| {
                outcome.presentation_error = err;
                return self.finishCommand(outcome, &validation, revisions[at]);
            };
            self.window.invalidate();
        } else outcome.presentation_error = error.LayoutRequired;
        return self.finishCommand(outcome, &validation, revisions[at]);
    }
    fn finishCommand(self: *State, value: CommandOutcome, validation: *CommandGuard, initial_revision: u64) !CommandOutcome {
        var outcome = value;
        // Presentation owns further fallible native/allocator calls. Observe
        // their effects before returning the receipt captured at text commit.
        const permission = CommandGuard.validate(validation);
        // The coordinator pins both Adapters/Documents and the Window scope
        // delays close callbacks; this owner-thread getter has no foreign call.
        outcome.observed_revision = self.documents()[@intFromEnum(outcome.side)].version() catch unreachable;
        if (outcome.observed_revision != (outcome.committed_revision orelse initial_revision)) {
            if (outcome.committed_revision == null) return error.StaleRevision;
            outcome.stale_after_commit = true;
            outcome.index_required = true;
            self.required = true;
            outcome.presentation_error = outcome.presentation_error orelse error.StaleRevision;
        }
        permission catch |err| {
            if (outcome.committed_revision == null) return err;
            outcome.stale_after_commit = true;
            self.required = true;
            outcome.presentation_error = outcome.presentation_error orelse err;
        };
        return outcome;
    }
    fn validatePresentation(self: *State, epoch: u64) !void {
        try self.live();
        if (epoch == 0 or self.presentation_epoch != epoch) return error.StalePresentation;
        const snapshot = self.snapshot orelse return error.LayoutRequired;
        _ = try self.current(snapshot.bounds, snapshot.parameters.scale);
        const borrow = try self.inbox.borrow();
        defer borrow.end();
        const display = try borrow.display();
        if ((if (display) |value| value.serial else @as(u64, 0)) != snapshot.serial) return error.StalePresentation;
    }
    fn validateAction(self: *State, epoch: u64) !void {
        try self.validatePresentation(epoch);
        _ = try self.coordinateGeneration();
        const state = try self.window.state();
        if (!state.enabled or state.modal_blocked) return error.Disabled;
        for (self.documents()) |document| if (try document.composition() != null) return error.CompositionActive;
    }
    fn validatePreparedAction(self: *State) !void {
        const epoch = self.action_epoch orelse return;
        try self.live();
        if (self.inbox.stopping) return error.Closed;
        if (self.presentation_epoch != epoch) return error.StalePresentation;
        _ = try self.coordinateGeneration();
        try self.validateInputScope();
        const state = try self.window.state();
        if (!state.enabled or state.modal_blocked) return error.Disabled;
        for (self.documents()) |document| if (try document.composition() != null) return error.CompositionActive;
    }
    fn validateInputScope(self: *State) !void {
        const generation = self.input_coordinate orelse return;
        try self.live();
        if (self.inbox.stopping) return error.Closed;
        if (generation != try self.coordinateGeneration()) return error.StalePresentation;
        const state = try self.window.state();
        if (!state.enabled or state.modal_blocked) return error.Disabled;
    }
    const SelectionGuard = struct {
        state: *State,
        peer: *d.Document,
        peer_revision: u64,
        epoch: u64,
        coordinate: ?u64 = null,
        fn validate(ptr: *anyopaque) !void {
            const guard: *@This() = @ptrCast(@alignCast(ptr));
            try guard.state.live();
            if (guard.state.inbox.stopping) return error.Closed;
            if (guard.state.presentation_epoch != guard.epoch) return error.StalePresentation;
            if (guard.coordinate != try guard.state.coordinateGeneration()) return error.StalePresentation;
            if (try guard.peer.version() != guard.peer_revision) return error.StaleRevision;
            if (try guard.peer.composition() != null) return error.CompositionActive;
            const state = try guard.state.window.state();
            if (!state.enabled or state.modal_blocked) return error.Disabled;
        }
    };
    fn prepareSelection(self: *State, side: Side, selections: []const d.Selection, primary: usize, revisions: [2]u64) !void {
        const at = @intFromEnum(side);
        const document = self.documents()[at];
        for (selections) |selected| {
            _ = try document.utf16Offset(selected.anchor);
            _ = try document.utf16Offset(selected.caret);
        }
        // Fold expansion has no Document mutation and is independently fallible.
        if (self.snapshot.?.projected) {
            for (selections) |selected| if (self.context_index) |*mapping| {
                const line = try document.lineAt(selected.caret);
                var lo: usize = 0;
                var hi = mapping.regions.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const lines = if (side == .a) mapping.regions[mid].a else mapping.regions[mid].b;
                    if (lines.end <= line) lo = mid + 1 else hi = mid;
                }
                if (lo < mapping.regions.len) {
                    const region = mapping.regions[lo];
                    const lines = if (side == .a) region.a else region.b;
                    if (region.collapsed and line >= lines.start) try self.reveal(side, selected.caret);
                }
            };
            const caret = try self.adapters[at].positionRect(revisions[at], selections[primary].caret, .downstream);
            const column = self.snapshot.?.columns[at];
            if (caret == null or caret.?.y + caret.?.height <= column.y or caret.?.y >= column.y + column.height) try self.reveal(side, selections[primary].caret);
        }
        for (self.documents(), revisions) |source, revision| if (try source.version() != revision) return error.StaleRevision;
    }
    fn selectPresented(self: *State, side: Side, selections: []const d.Selection, primary: usize) !SelectionOutcome {
        const at = @intFromEnum(side);
        const document = self.documents()[at];
        const revisions = [2]u64{ try self.documents()[0].version(), try self.documents()[1].version() };
        const coordinate = try self.coordinateGeneration();
        try self.prepareSelection(side, selections, primary, revisions);
        var validation: SelectionGuard = .{ .state = self, .peer = self.documents()[1 - at], .peer_revision = revisions[1 - at], .epoch = self.presentation_epoch, .coordinate = coordinate };
        const guard = try document.beginCommitGuard(.{ .context = &validation, .validate = SelectionGuard.validate });
        const changed = self.adapters[at].setSelections(selections, primary) catch |err| {
            guard.end();
            return err;
        };
        guard.end();
        const previous = self.snapshot.?;
        self.required = true;
        var parameters = previous.parameters;
        parameters.font = previous.font.get();
        self.prepare(previous.bounds, parameters) catch |err| return .{ .changed = changed, .presentation_error = self.budget.normalize(err) };
        self.window.invalidate();
        return .{ .changed = changed };
    }
    fn nativeChanged(ptr: *anyopaque, window: z.Window, adapter: *editing.Adapter, change: editing.NativeChange) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.busy) {
            self.required = true;
            return error.Busy;
        }
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        const coordinate = try self.coordinateGeneration();
        const snapshot = if (self.snapshot) |*value| value else return error.LayoutRequired;
        var parameters = snapshot.parameters;
        parameters.font = snapshot.font.get();
        const bounds = snapshot.bounds;
        self.required = true;
        if (change.layout_error == null and !snapshot.composing) {
            const fresh = fresh: {
                const borrow = try self.inbox.borrow();
                defer borrow.end();
                break :fresh (try borrow.display()) != null;
            };
            if (fresh and try self.inbox.pair.a.composition() == null and try self.inbox.pair.b.composition() == null) try self.adopt(if (adapter == self.adapters[0]) 0 else 1);
        }
        self.prepare(bounds, parameters) catch |err| return self.budget.normalize(err);
        if (coordinate != try self.coordinateGeneration()) return error.StalePresentation;
    }
    fn nativeAuthority(ptr: *anyopaque, window: z.Window, _: *editing.Adapter, bound_space: ?ui.SpaceBinding) !?u64 {
        const self: *State = @ptrCast(@alignCast(ptr));
        const space = self.coordinates orelse return if (self.coordinate_policy) error.GeometryRequired else null;
        if (!std.meta.eql(self.window, window)) return error.ForeignWindow;
        const generation = try self.coordinateGeneration();
        if (!std.meta.eql(space.value.space, bound_space)) return error.StaleSpace;
        return generation;
    }
    fn coordinateGeneration(self: *State) !?u64 {
        const space = self.coordinates orelse return if (self.coordinate_policy) error.GeometryRequired else null;
        const snapshot = self.snapshot orelse return error.LayoutRequired;
        return (try space.value.resolve(self.window, snapshot.columns, snapshot.parameters.scale)).generation;
    }
    fn focus(self: *State, side: Side) !void {
        if (self.coordinate_policy and self.coordinates == null) return error.GeometryRequired;
        if (self.mode == .unified and side != .b) return error.ReadOnlySource;
        if (self.acquisition_generation == std.math.maxInt(u64)) return error.IdExhausted;
        const snapshot = self.snapshot orelse return error.LayoutRequired;
        _ = try self.current(snapshot.bounds, snapshot.parameters.scale);
        const coordinate = if (self.coordinates) |space| try space.value.resolve(self.window, snapshot.columns, snapshot.parameters.scale) else null;
        if (self.focused) |previous| if (previous != side) {
            self.focused = null;
            try self.adapters[@intFromEnum(previous)].unbind();
            if (try self.inbox.pair.a.version() != snapshot.revisions[0] or try self.inbox.pair.b.version() != snapshot.revisions[1]) {
                const old = self.snapshot.?;
                var parameters = old.parameters;
                parameters.font = old.font.get();
                try self.prepare(old.bounds, parameters);
            }
        };
        if (self.window.isClosed()) return error.Closed;
        const target = self.adapters[@intFromEnum(side)];
        const was_bound = try target.isBound();
        target.bind(self.window) catch |err| if (err != error.AlreadyBound) return err;
        errdefer if (coordinate != null and !was_bound) target.unbind() catch |err| self.window.report(.{ .domain = .core, .operation = .text_input, .err = err });
        if (self.window.isClosed()) return error.Closed;
        if (coordinate) |accepted| {
            const fresh = try self.coordinates.?.value.resolve(self.window, snapshot.columns, snapshot.parameters.scale);
            if (accepted.generation != fresh.generation) return error.StalePresentation;
            try self.adapters[@intFromEnum(side)].setCommittedSpace(fresh.token);
        }
        self.focused = side;
        // Native acquisition already succeeded. A later caret presentation
        // failure must not leave a previous source authorization usable.
        self.last_active = side;
        self.acquisition_generation += 1;
        try self.syncCaret();
        self.window.invalidate();
    }
    fn syncCaret(self: *State) !void {
        if (self.coordinate_policy and self.coordinates == null) return error.GeometryRequired;
        const side = self.focused orelse return;
        if (!try self.adapters[@intFromEnum(side)].isBound()) return;
        const snapshot = self.snapshot orelse return;
        if (self.coordinates) |space| {
            _ = try space.value.resolve(self.window, snapshot.columns, snapshot.parameters.scale);
            // The Adapter captures the physical client/space/lease before the
            // native operation and checks them again after any reentry.
            try self.adapters[@intFromEnum(side)].syncNativeCaret();
            return;
        }
        const caret = self.adapters[@intFromEnum(side)].caretRect(snapshot.columns[@intFromEnum(side)], snapshot.parameters.scale) catch |err| {
            if (err == error.CaretNotVisible) return;
            return err;
        };
        try self.window.setTextCaret(.{ .x = caret.x, .y = caret.y, .width = caret.width, .height = caret.height });
        if (self.window.isClosed()) return error.Closed;
    }
    fn current(self: *State, bounds: ui.Rect, scale: f32) !*const Snapshot {
        if (self.required) return error.LayoutRequired;
        const snapshot = if (self.snapshot) |*value| value else return error.LayoutRequired;
        if (!std.meta.eql(snapshot.bounds, bounds) or snapshot.parameters.scale != scale) return error.LayoutRequired;
        if (self.inbox.stopping) return error.Closed;
        for (self.documents(), self.adapters, snapshot.revisions, snapshot.view_versions) |document, adapter, revision, version| {
            if (try document.version() != revision or try adapter.viewVersion() != version) return error.LayoutRequired;
        }
        return snapshot;
    }
    fn prepare(self: *State, bounds: ui.Rect, parameters: Parameters) !void {
        if (self.presentation_epoch == std.math.maxInt(u64)) return error.IdExhausted;
        self.required = true;
        if (!ui.layout.validRect(bounds) or bounds.width < 80 or bounds.height <= 0 or bounds.width > 1000000 or bounds.height > 1000000) return error.InvalidGeometry;
        if (parameters.font.family.len > 255 or parameters.font.locale.len > 127) return error.InvalidParameters;
        const width = (bounds.width - 8) / 2;
        var columns: [2]ui.Rect = if (self.mode == .unified) @splat(bounds) else .{ .{ .x = bounds.x, .y = bounds.y, .width = width, .height = bounds.height }, .{ .x = bounds.x + width + 8, .y = bounds.y, .width = width, .height = bounds.height } };
        if (self.context_options != null) for (&columns) |*column| {
            column.x += 12;
            column.width -= 12;
        };
        const options: [2]editing.Parameters = @splat(.{ .font = parameters.font, .scale = parameters.scale, .version = parameters.version, .estimated_height = parameters.estimated_height });
        const borrow = try self.inbox.borrow();
        defer borrow.end();
        const display = try borrow.display();
        const composing = try self.inbox.pair.a.composition() != null or try self.inbox.pair.b.composition() != null;
        var contexts: ContextTransaction = .{ .state = self, .display = display, .composing = composing };
        defer contexts.close();
        try contexts.construct(columns, options);
        for (self.adapters, self.fold_tokens) |adapter, token| {
            const stats = try adapter.stats();
            if (token == null and stats.visible_paragraphs < stats.paragraphs) return error.FoldedDocument;
        }
        var candidate: Snapshot = .{ .bounds = bounds, .columns = columns, .parameters = parameters, .revisions = undefined, .view_versions = undefined, .serial = if (display) |value| value.serial else 0, .projected = display != null and !composing, .composing = composing };
        candidate.font.set(parameters.font);
        candidate.parameters.font = candidate.font.options;
        var index: ?ix.Index = null;
        defer if (index) |*value| value.close();
        const rebuild = display != null and !composing and (contexts.changed or self.context_index_required or self.index == null or self.serial != display.?.serial or if (self.snapshot) |*old| !sameGeometry(old, &candidate) else true);
        if (rebuild) {
            index = if (self.mode == .unified) try unified_index.create(self.budget.allocator(), &display.?.result, self.limits.rows, self.limits.index_bytes, parameters.estimated_height) else try ix.Index.create(self.budget.allocator(), &display.?.result, self.limits.rows, self.limits.index_bytes, parameters.estimated_height);
            if (contexts.mapping()) |mapping| {
                var projected = try mapping.project(self.budget.allocator(), &index.?, self.limits.index_bytes);
                std.mem.swap(ix.Index, &projected, &index.?);
                projected.close();
            }
        }
        var transaction: Transaction = .{ .state = self, .index = if (index) |*value| value else if (self.index) |*value| value else null, .display = display, .snapshot = &candidate, .anchor = self.anchor };
        defer transaction.close();
        if (rebuild) if (self.snapshot) |previous| if (!previous.projected and !previous.composing) if (self.focused) |side| {
            const at = @intFromEnum(side);
            if (self.adapters[at].viewportAnchor()) |source| {
                const aligned = sourceRow(transaction.index.?, at, source.line) orelse transaction.index.?.heights.len;
                transaction.anchor = .{ .row = aligned, .intra = source.intra_ticks };
            } else |_| {}
        };
        if (self.reveal_raw orelse contexts.old_raw_anchor) |requested| if (transaction.index != null and transaction.index.?.heights.len != 0) {
            var row = requested;
            if (contexts.mapping()) |mapping| {
                const raw = @min(requested, mapping.raw_rows - 1);
                row = (try mapping.rawToVisible(raw)) orelse (try mapping.rawToVisible(mapping.regions[(try mapping.containing(raw)).?].first - 1)).?;
            }
            transaction.anchor = .{ .row = row };
        };
        // Context folds and their viewport are one transaction. Reserve all
        // marker storage and inspect completed candidate geometry before the
        // pair's pure publication, without a second layout or native query.
        var mark_buffers: MarkBuffers = .{};
        defer mark_buffers.close(self.budget.allocator());
        if (contexts.folds != null and candidate.projected) if (display.?.details) |details| if (details.spans.len != 0) {
            mark_buffers.storage = try self.budget.allocator().alloc(IntralineMark, self.limits.intraline_rects);
            mark_buffers.scratch = try self.budget.allocator().alloc(t.Rect, self.limits.intraline_rects);
        };
        if (contexts.folds != null and !composing) transaction.mark_buffers = &mark_buffers;
        const planner: editing.PairPlanner = .{ .context = &transaction, .build = Transaction.build, .validate = if (self.input_coordinate != null) Transaction.validateInput else null, .prepared = if (transaction.mark_buffers != null or self.action_epoch != null) Transaction.complete else null };
        const output = if (contexts.folds) |folds| try editing.projectPairWithFolds(self.window, self.adapters[0], self.adapters[1], columns, options, planner, folds) else try editing.projectPair(self.window, self.adapters[0], self.adapters[1], columns, options, planner);
        candidate.composing = output.projection_suspended;
        candidate.projected = display != null and !output.projection_suspended;
        // A successful pair result always published ownership, even if a
        // foreign old-resource destructor then invalidated its presentation.
        contexts.publish();
        if (index != null and candidate.projected) std.mem.swap(?ix.Index, &self.index, &index);
        if (candidate.projected) self.context_index_required = false;
        transaction.committed = true;
        const old_plans = self.plans;
        if (!output.projection_suspended) self.plans = transaction.plans;
        transaction.created = @splat(false);
        const marks_prepared = transaction.marks != null;
        var old_marks: []IntralineMark = &.{};
        if (transaction.marks) |marks| {
            old_marks = self.marks.storage;
            self.marks = marks;
            transaction.marks = null;
        }
        self.budget.allocator().free(old_marks);
        for (old_plans, self.plans) |old, next| if (old != next) if (old) |owned| owned.close() catch unreachable;
        var retired: ?ix.Index = null;
        std.mem.swap(?ix.Index, &retired, &index);
        if (retired) |*old| old.close();
        try contexts.finish();
        try self.validateInputScope();
        if (!output.current) return output.post_publish_error orelse error.LayoutRequired;
        for (self.documents(), self.adapters, &candidate.revisions, &candidate.view_versions) |document, adapter, *revision, *version| {
            revision.* = try document.version();
            version.* = try adapter.viewVersion();
        }
        if (self.window.isClosed()) return error.Closed;
        if (display) |value| if (!try self.inbox.fresh(value.result.a, value.result.b)) return error.StaleRevision;
        if (!output.projection_suspended) self.anchor = transaction.anchor;
        self.serial = candidate.serial;
        if (display) |value| {
            if (self.selected) |at| {
                if (at >= value.result.hunks.len) self.selected = if (value.result.hunks.len == 0) null else value.result.hunks.len - 1;
            } else if (value.result.hunks.len != 0) self.selected = 0;
        }
        if (!marks_prepared) try self.prepareMarks(&candidate, display, &mark_buffers);
        try self.validateInputScope();
        self.snapshot = candidate;
        self.reveal_raw = null;
        self.required = false;
        errdefer self.required = true;
        self.syncCaret() catch |err| {
            // Preparing new local bounds must remain possible while the old
            // successful front still owns coordinates. Input stays gated until
            // the new matching front; do not shape or bind from its publication.
            if (!self.coordinate_policy or (err != error.GeometryRequired and err != error.StaleSpace and err != error.StalePresentation and err != error.SpaceNotFound and err != error.NotVisible)) return err;
        };
        _ = try self.current(bounds, parameters.scale);
        self.presentation_epoch += 1;
        self.layout_updates +|= 1;
    }
    fn contextRegions(self: *State, output: []ContextRegion) ![]const ContextRegion {
        const previous = self.snapshot orelse return error.LayoutRequired;
        const snapshot = try self.current(previous.bounds, previous.parameters.scale);
        const mapping = if (self.context_index) |*value| value else return output[0..0];
        if (!snapshot.projected) return output[0..0];
        var count: usize = 0;
        for (snapshot.rows[0..snapshot.count]) |row| {
            const line = row.b orelse continue;
            var lo: usize = 0;
            var hi = mapping.regions.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (mapping.regions[mid].b.start - 1 < line) lo = mid + 1 else hi = mid;
            }
            if (lo == mapping.regions.len or mapping.regions[lo].b.start - 1 != line) continue;
            if (count == output.len) return error.CapacityExceeded;
            const region = mapping.regions[lo];
            var headers: [2]?ui.Rect = @splat(null);
            for (snapshot.columns, &headers, 0..) |column, *header, side| {
                if (self.mode == .unified and side == 0) continue;
                const rectangle = ui.layout.intersect(snapshot.bounds, .{ .x = column.x - 12, .y = column.y + row.y + 2, .width = 10, .height = @min(12, @max(0, row.height - 2)) });
                if (rectangle.width > 0 and rectangle.height > 0) header.* = rectangle;
            }
            output[count] = .{ .key = .{ .serial = self.context_serial, .id = region.id }, .collapsed = region.collapsed, .a = region.a, .b = region.b, .headers = headers };
            count += 1;
        }
        return output[0..count];
    }
    fn changeContext(self: *State, key: ContextKey, collapsed: bool, reveal_row: ?usize) !bool {
        const old = self.snapshot orelse return error.LayoutRequired;
        _ = try self.current(old.bounds, old.parameters.scale);
        const mapping = if (self.context_index) |*value| value else return error.ContextDisabled;
        if (key.serial != self.context_serial) return error.StaleContext;
        {
            const borrow = try self.inbox.borrow();
            defer borrow.end();
            const display = try borrow.display() orelse return error.ComparisonRequired;
            if (display.serial != key.serial) return error.StaleContext;
        }
        const at = mapping.find(key.id) orelse return error.FoldNotFound;
        if (mapping.regions[at].collapsed == collapsed and reveal_row == null) return false;
        self.pending_context = .{ .key = key, .collapsed = collapsed };
        self.reveal_raw = reveal_row;
        var parameters = old.parameters;
        parameters.font = old.font.get();
        self.prepare(old.bounds, parameters) catch |err| {
            if (self.pending_context != null) {
                self.pending_context = null;
                self.reveal_raw = null;
            }
            return err;
        };
        self.window.invalidate();
        return true;
    }
    fn reveal(self: *State, side: Side, position: usize) !void {
        const old = self.snapshot orelse return error.LayoutRequired;
        _ = try self.current(old.bounds, old.parameters.scale);
        const document = self.documents()[@intFromEnum(side)];
        _ = try document.utf16Offset(position);
        const line = try document.lineAt(position);
        if (self.context_index) |*mapping| for (mapping.regions) |region| {
            const lines = if (side == .a) region.a else region.b;
            if (line >= lines.start and line < lines.end) {
                _ = try self.changeContext(.{ .serial = self.context_serial, .id = region.id }, false, region.first + line - lines.start);
                return;
            }
        };
        const row = if (self.index) |*index| sourceRow(index, @intFromEnum(side), line) else null;
        if (row) |value| {
            self.anchor = .{ .row = value };
            var parameters = old.parameters;
            parameters.font = old.font.get();
            try self.prepare(old.bounds, parameters);
            self.window.invalidate();
        } else return error.ComparisonRequired;
    }
    fn prepareMarks(self: *State, snapshot: *const Snapshot, display: ?*const requests.Display, buffers: *MarkBuffers) !void {
        const versions = [2]u64{ try self.adapters[0].projectionVersion(), try self.adapters[1].projectionVersion() };
        const details: ?*const intraline.Result = if (snapshot.projected) if (display.?.details) |*value| value else null else null;
        const serial: u64 = if (details != null) snapshot.serial else 0;
        if (self.marks.serial == serial and std.meta.eql(self.marks.versions, versions)) return;
        const allocator = self.budget.allocator();
        var candidate: Marks = .{ .serial = serial, .versions = versions };
        errdefer allocator.free(candidate.storage);
        if (details) |value| if (value.spans.len != 0) {
            if (buffers.storage.len != 0) std.mem.swap([]IntralineMark, &candidate.storage, &buffers.storage) else candidate.storage = try allocator.alloc(IntralineMark, self.limits.intraline_rects);
            var scratch: []t.Rect = &.{};
            if (buffers.scratch.len != 0) std.mem.swap([]t.Rect, &scratch, &buffers.scratch) else scratch = try allocator.alloc(t.Rect, self.limits.intraline_rects);
            defer allocator.free(scratch);
            try collectMarks(self, snapshot, value, self.adapters, &candidate, scratch);
        };
        try self.validateMarksSnapshot(snapshot);
        // Pair publication already committed its Plans. A marks failure above
        // leaves old marks owned and the caller explicitly LayoutRequired.
        // On success adopt candidate before any foreign allocator destructor.
        const previous = self.marks.storage;
        self.marks = candidate;
        candidate.storage = &.{};
        allocator.free(previous);
        try self.validateMarksSnapshot(snapshot);
    }
    fn validateMarksSnapshot(self: *State, snapshot: *const Snapshot) !void {
        if (self.window.isClosed()) return error.Closed;
        for (self.documents(), self.adapters, snapshot.revisions, snapshot.view_versions) |document, adapter, revision, version| {
            if (try document.version() != revision) return error.StaleRevision;
            if (try adapter.viewVersion() != version) return error.LayoutRequired;
        }
    }
    fn adopt(self: *State, side: usize) !void {
        const index = if (self.index) |*value| value else return;
        if (index.heights.len == 0) return;
        const source = try self.adapters[side].viewportAnchor();
        const plan = self.plans[side] orelse return;
        var gap: u128 = 0;
        for (plan.records) |record| if (record.line == source.line) {
            gap = record.gap;
            break;
        };
        const row = sourceRow(index, side, source.line) orelse index.heights.len;
        // A source anchor may lie in an insertion gap belonging to the next
        // real paragraph. Compare integers before converting any local DIP.
        const base = @as(u128, index.prefix(row)) << canonical_shift;
        const position = if (source.intra_ticks >= gap) base + source.intra_ticks - gap else base -| (gap - source.intra_ticks);
        const total = @as(u128, index.prefix(index.heights.len)) << canonical_shift;
        const target = @min(position, total - 1);
        const located = index.locate(@intCast(target >> canonical_shift));
        self.anchor = .{ .row = located.row, .intra = target - (@as(u128, index.prefix(located.row)) << canonical_shift) };
    }
    fn scroll(self: *State, delta: f32) !bool {
        if (!std.math.isFinite(delta) or @abs(delta) > 1000000) return error.InvalidScroll;
        const index = if (self.index) |*value| value else return false;
        if (index.heights.len == 0) return false;
        const viewport = if (self.snapshot) |value| value.bounds.height else 1;
        const position = (@as(u128, index.prefix(@min(self.anchor.row, index.heights.len))) << canonical_shift) + self.anchor.intra;
        const total = @as(u128, index.prefix(index.heights.len)) << canonical_shift;
        const amount = @round(@as(f64, delta) * canonical_units);
        const magnitude: u128 = @intFromFloat(@abs(amount));
        const maximum = total -| @as(u128, @intFromFloat(@ceil(@as(f64, viewport) * canonical_units)));
        const target = @min(if (amount < 0) position -| magnitude else position +| magnitude, maximum);
        const located = index.locate(@intCast(target >> canonical_shift));
        const anchor: Anchor = .{ .row = located.row, .intra = target - (@as(u128, index.prefix(located.row)) << canonical_shift) };
        if (std.meta.eql(anchor, self.anchor)) return false;
        self.anchor = anchor;
        self.required = true;
        return true;
    }
    fn navigate(self: *State, forward: bool) !bool {
        const borrow = try self.inbox.borrow();
        defer borrow.end();
        const display = try borrow.display() orelse return false;
        const index = if (self.index) |*value| value else return error.LayoutRequired;
        if (display.serial != self.serial) return error.LayoutRequired;
        if (display.result.hunks.len == 0) return false;
        const at = if (self.selected) |value| if (forward) @min(value + 1, display.result.hunks.len - 1) else value -| 1 else 0;
        self.anchor = .{ .row = index.hunkRow(at) orelse return error.InvalidResult };
        self.selected = at;
        self.required = true;
        return true;
    }
    fn revert(self: *State, hunk: usize, direction: Direction) !editing.EditResult {
        if (self.mode == .unified and direction != .a_to_b) return error.ReadOnlySource;
        const borrow = try self.inbox.borrow();
        defer borrow.end();
        const display = try borrow.display() orelse return error.ComparisonRequired;
        if (hunk >= display.result.hunks.len) return error.InvalidHunk;
        for (self.documents()) |document| if (try document.composition() != null) return error.CompositionActive;
        const selected = display.result.hunks[hunk];
        const source = if (direction == .a_to_b) display.a else display.b;
        const range = if (direction == .a_to_b) selected.a.bytes else selected.b.bytes;
        const target = if (direction == .a_to_b) selected.b.bytes else selected.a.bytes;
        const side: usize = if (direction == .a_to_b) 1 else 0;
        if (range.end - range.start > self.limits.revert_bytes) return error.CapacityExceeded;
        const revision = try self.documents()[side].version();
        const coordinate = try self.coordinateGeneration();
        const bytes = try self.budget.allocator().alloc(u8, range.end - range.start);
        defer self.budget.allocator().free(bytes);
        _ = try source.read(range, bytes);
        if (self.window.isClosed()) return error.Closed;
        if (!try self.inbox.fresh(display.result.a, display.result.b)) return error.StaleRevision;
        var validation: SelectionGuard = .{ .state = self, .peer = self.documents()[1 - side], .peer_revision = self.snapshot.?.revisions[1 - side], .epoch = self.action_epoch orelse self.presentation_epoch, .coordinate = coordinate };
        const guard = if (self.action_epoch != null or self.input_coordinate != null) try self.documents()[side].beginCommitGuard(.{ .context = &validation, .validate = SelectionGuard.validate }) else null;
        defer if (guard) |scope| scope.end();
        const result = try self.adapters[side].replaceMany(revision, &.{.{ .range = target, .text = bytes }});
        self.required = true;
        self.window.invalidate();
        return result;
    }
    fn event(self: *State, event_value: z.Event, bounds: ui.Rect, parameters: Parameters) !bool {
        if (event_value == .wheel) {
            if (!bounds.contains(event_value.wheel.position)) return false;
            if (try self.inbox.pair.a.composition() != null or try self.inbox.pair.b.composition() != null) {
                const side = self.focused orelse return false;
                const snapshot = self.snapshot orelse return error.LayoutRequired;
                const at = @intFromEnum(side);
                const used = try self.adapters[at].handleEvent(self.window, event_value, snapshot.columns[at], .{ .font = parameters.font, .scale = parameters.scale, .version = parameters.version, .estimated_height = parameters.estimated_height });
                try self.prepare(bounds, parameters);
                return used;
            }
            _ = try self.scroll(event_value.wheel.delta.y);
            try self.prepare(bounds, parameters);
            self.window.invalidate();
            return true;
        }
        if (event_value == .key_input) {
            const key = event_value.key_input;
            const composing = try self.inbox.pair.a.composition() != null or try self.inbox.pair.b.composition() != null;
            if (!composing and !key.modifiers.control and !key.modifiers.alt and !key.modifiers.super and key.key == .f7) {
                _ = try self.navigate(!key.modifiers.shift);
                try self.prepare(bounds, parameters);
                self.window.invalidate();
                return true;
            }
            if (!composing and key.modifiers.control and !key.modifiers.alt and !key.modifiers.super and key.key == .enter and self.selected != null) {
                _ = try self.revert(self.selected.?, .a_to_b);
                try self.prepare(bounds, parameters);
                return true;
            }
        }
        if (event_value == .pointer_down) {
            const snapshot = self.snapshot orelse return false;
            if (snapshot.projected and self.context_index != null) {
                var headers: [max_rows]ContextRegion = undefined;
                for (try self.contextRegions(&headers)) |region| for (region.headers) |header| if (header) |rectangle| {
                    if (rectangle.contains(event_value.pointer_down.position)) {
                        _ = try self.changeContext(region.key, !region.collapsed, null);
                        return true;
                    }
                };
            }
            if (self.mode == .unified) {
                if (!bounds.contains(event_value.pointer_down.position)) return false;
                try self.focus(.b);
                if (snapshot.projected) for (snapshot.rows[0..snapshot.count]) |row| {
                    if (event_value.pointer_down.position.y < bounds.y + row.y or event_value.pointer_down.position.y >= bounds.y + row.y + row.height) continue;
                    if (row.hunk) |hunk| self.selected = hunk;
                    if (row.b == null) {
                        // A ghost is a display/hunk target. It is deliberately
                        // never translated into a fabricated modified offset.
                        self.window.invalidate();
                        return true;
                    }
                    break;
                };
            } else for (snapshot.columns, 0..) |column, side| if (column.contains(event_value.pointer_down.position)) {
                try self.focus(@enumFromInt(side));
                break;
            };
        }
        if (event_value == .focus) {
            if (!event_value.focus) if (self.focused) |side| {
                const snapshot = self.snapshot orelse return false;
                _ = try self.adapters[@intFromEnum(side)].handleEvent(self.window, event_value, snapshot.columns[@intFromEnum(side)], .{ .font = parameters.font, .scale = parameters.scale, .version = parameters.version, .estimated_height = parameters.estimated_height });
            };
            // Revoking the native client can cancel Document composition
            // before focus(false) arrives, without a separate UI text event.
            try self.prepare(bounds, parameters);
            if (event_value.focus) if (self.focused) |side| try self.focus(side);
            return false;
        }
        if (event_value == .resize) {
            try self.prepare(bounds, parameters);
            return false;
        }
        const side = self.focused orelse return false;
        const snapshot = self.snapshot orelse return error.LayoutRequired;
        const at = @intFromEnum(side);
        const text_stamps: [2]u64 = .{ try self.inbox.pair.a.committedTextVersion(), try self.inbox.pair.b.committedTextVersion() };
        const was_composing = try self.inbox.pair.a.composition() != null or try self.inbox.pair.b.composition() != null;
        const used = try self.adapters[at].handleEvent(self.window, event_value, snapshot.columns[at], .{ .font = parameters.font, .scale = parameters.scale, .version = parameters.version, .estimated_height = parameters.estimated_height });
        if (!used) return false;
        if (!was_composing and try self.inbox.pair.a.composition() == null and try self.inbox.pair.b.composition() == null and text_stamps[0] == try self.inbox.pair.a.committedTextVersion() and text_stamps[1] == try self.inbox.pair.b.committedTextVersion()) try self.adopt(at);
        self.required = true;
        try self.prepare(bounds, parameters);
        self.window.invalidate();
        return true;
    }
};
const ContextTransaction = struct {
    state: *State,
    display: ?*const requests.Display,
    composing: bool,
    want: bool = false,
    changed: bool = false,
    drop: bool = false,
    candidate: ?context.Index = null,
    definitions: [2][]editing.Fold = @splat(&.{}),
    folds: ?editing.PairFolds = null,
    old_raw_anchor: ?usize = null,
    fn close(self: *ContextTransaction) void {
        if (self.candidate) |*value| value.close();
        self.candidate = null;
        const definitions = self.definitions;
        self.definitions = @splat(&.{});
        const allocator = self.state.budget.allocator();
        for (definitions) |items| allocator.free(items);
    }
    fn mapping(self: *ContextTransaction) ?*context.Index {
        if (!self.want) return null;
        return if (self.candidate) |*value| value else if (self.state.context_index) |*value| value else null;
    }
    fn validate(self: *ContextTransaction, revisions: [2]u64) !void {
        const state = self.state;
        if (state.window.isClosed()) return error.Closed;
        for (state.documents(), revisions) |document, revision| if (try document.version() != revision) return error.StaleRevision;
        if (self.display) |value| if (!try state.inbox.fresh(value.result.a, value.result.b)) return error.StaleRevision;
    }
    fn construct(self: *ContextTransaction, bounds: [2]ui.Rect, parameters: [2]editing.Parameters) !void {
        const state = self.state;
        self.want = self.display != null and !self.composing and state.context_options != null;
        if (state.fold_tokens[0] == null and !self.want) return;
        if (state.fold_tokens[0] == null) {
            const a = try state.adapters[0].reserveFolds();
            const b = state.adapters[1].reserveFolds() catch |err| {
                _ = state.adapters[0].releaseFolds(a) catch unreachable;
                return err;
            };
            state.fold_tokens = .{ a, b };
        }
        const tokens: [2]editing.FoldToken = .{ state.fold_tokens[0].?, state.fold_tokens[1].? };
        const status = .{ try state.adapters[0].status(), try state.adapters[1].status() };
        if (status[0].index_required or status[0].folds_required or status[1].index_required or status[1].folds_required) {
            // An unknown external revision is a separate explicit rebuild
            // boundary. It cannot be reverse-mapped through old fold ranges.
            for (state.adapters, tokens) |adapter, token| _ = try adapter.clearOwnedFolds(token);
            const result = try editing.preparePair(state.window, state.adapters[0], state.adapters[1], bounds, parameters);
            if (!result.current) return result.post_publish_error orelse error.LayoutRequired;
        }
        const revisions = [2]u64{ try state.inbox.pair.a.version(), try state.inbox.pair.b.version() };
        const same = self.want and state.context_index != null and state.context_serial == self.display.?.serial and state.applied_context_generation == state.context_generation;
        const allocator = state.budget.allocator();
        if (self.want and (!same or state.pending_context != null)) {
            self.candidate = if (same) try state.context_index.?.clone(allocator) else try context.Index.create(allocator, &self.display.?.result, @enumFromInt(@intFromEnum(state.mode)), state.context_options.?);
            try self.validate(revisions);
            if (state.pending_context) |action| {
                if (action.key.serial != self.display.?.serial) return error.StaleContext;
                _ = try self.candidate.?.setCollapsed(action.key.id, action.collapsed);
            }
        }
        self.drop = (!self.composing or state.context_options == null) and !self.want and state.context_index != null;
        self.changed = self.candidate != null or self.drop;
        if (self.changed and state.reveal_raw == null and state.serial == (if (self.display) |value| value.serial else 0)) self.old_raw_anchor = if (state.context_index) |*value| value.visibleToRaw(state.anchor.row) catch 0 else state.anchor.row;
        const versions = [2]u64{ (try state.adapters[0].status()).fold_version, (try state.adapters[1].status()).fold_version };
        const need = self.candidate != null or self.want != state.context_active or !std.meta.eql(versions, state.fold_versions) or (!self.want and ((try state.adapters[0].stats()).folds != 0 or (try state.adapters[1].stats()).folds != 0));
        if (!need) return;
        if (self.mapping()) |value| for (state.documents(), &self.definitions, 0..) |document, *items, side| {
            items.* = try allocator.alloc(editing.Fold, value.regions.len);
            try self.validate(revisions);
            for (value.regions, items.*) |region, *fold| {
                const lines = if (side == 0) region.a else region.b;
                const end = if (lines.end < try document.lineCount()) (try document.line(lines.end)).start else try document.byteLength();
                fold.* = .{ .id = region.id, .header = (try document.line(lines.start - 1)).start, .end = end, .collapsed = region.collapsed };
            }
        };
        try self.validate(revisions);
        self.folds = .{ .tokens = tokens, .revisions = revisions, .definitions = .{ self.definitions[0], self.definitions[1] } };
    }
    /// Both Adapter roots/layouts are already committed. Transfer only plain
    /// metadata here; no old resources are released before Plans/index adoption.
    fn publish(self: *ContextTransaction) void {
        const state = self.state;
        if (state.fold_tokens[0] == null and self.candidate == null and !self.drop) return;
        if (self.candidate != null) {
            std.mem.swap(?context.Index, &self.candidate, &state.context_index);
            state.context_serial = self.display.?.serial;
            state.applied_context_generation = state.context_generation;
            state.pending_context = null;
        } else if (self.drop) {
            std.mem.swap(?context.Index, &self.candidate, &state.context_index);
            state.context_serial = 0;
            state.applied_context_generation = state.context_generation;
            state.pending_context = null;
        }
        state.context_index_required = state.context_index_required or self.changed;
        state.context_active = self.want;
        if (state.reveal_raw == null) state.reveal_raw = self.old_raw_anchor;
        state.fold_versions = .{ (state.adapters[0].status() catch unreachable).fold_version, (state.adapters[1].status() catch unreachable).fold_version };
    }
    fn finish(self: *ContextTransaction) !void {
        const state = self.state;
        if (state.context_options == null) for (state.adapters, &state.fold_tokens) |adapter, *token| if (token.*) |value| {
            std.debug.assert(try adapter.releaseFolds(value));
            token.* = null;
        };
        self.close();
    }
};
fn collectMarks(state: *State, snapshot: *const Snapshot, details: *const intraline.Result, sources: anytype, candidate: *Marks, scratch: []t.Rect) !void {
    for (sources, 0..) |adapter, side| for (snapshot.rows[0..snapshot.count]) |row| {
        const line = (if (side == 0) row.a else row.b) orelse continue;
        var first: usize = 0;
        var end = details.spans.len;
        while (first < end) {
            const middle = first + (end - first) / 2;
            if ((if (side == 0) details.spans[middle].line_a else details.spans[middle].line_b) < line) first = middle + 1 else end = middle;
        }
        while (first < details.spans.len) : (first += 1) {
            const span = details.spans[first];
            if ((if (side == 0) span.line_a else span.line_b) != line) break;
            const range = if (side == 0) span.a else span.b;
            state.intraline_queries +|= 1;
            const rectangles = try adapter.rangeRects(snapshot.revisions[side], range, scratch);
            for (rectangles) |rectangle| try appendMark(candidate, side, rectangle);
            // Empty edits and line-terminator-only ranges have no
            // advance cell; use the same cached source caret instead.
            if (rectangles.len == 0) if (try adapter.positionRect(snapshot.revisions[side], range.start, .downstream)) |rectangle| try appendMark(candidate, side, rectangle);
        }
    };
}
fn appendMark(marks: *Marks, side: usize, rectangle: t.Rect) !void {
    if (marks.count == marks.storage.len) return error.IntralineRectangleCapacityExceeded;
    marks.storage[marks.count] = .{ .side = @enumFromInt(side), .rect = .{ .x = rectangle.x, .y = rectangle.y, .width = rectangle.width, .height = rectangle.height } };
    marks.count += 1;
}

fn sameGeometry(a: *const Snapshot, b: *const Snapshot) bool {
    const x = a.parameters;
    const y = b.parameters;
    const fa = a.font.get();
    const fb = b.font.get();
    return a.columns[0].width == b.columns[0].width and x.version == y.version and x.scale == y.scale and x.estimated_height == y.estimated_height and fa.size == fb.size and fa.weight == fb.weight and fa.italic == fb.italic and fa.wrap == fb.wrap and fa.direction == fb.direction and std.mem.eql(u8, fa.family, fb.family) and std.mem.eql(u8, fa.locale, fb.locale);
}

const Transaction = struct {
    state: *State,
    index: ?*ix.Index,
    display: ?*const requests.Display,
    snapshot: *Snapshot,
    anchor: Anchor,
    plans: [2]?*editing.ProjectionPlan = @splat(null),
    created: [2]bool = @splat(false),
    changes: [max_rows]struct { row: usize, previous: u64 } = undefined,
    change_count: usize = 0,
    committed: bool = false,
    mark_buffers: ?*MarkBuffers = null,
    marks: ?Marks = null,
    fn validateInput(ptr: *anyopaque) !void {
        const self: *Transaction = @ptrCast(@alignCast(ptr));
        try self.state.validateInputScope();
    }
    fn close(self: *Transaction) void {
        if (self.marks) |marks| self.state.budget.allocator().free(marks.storage);
        self.marks = null;
        for (self.plans, self.created) |plan, created| if (created) plan.?.close() catch unreachable;
        if (!self.committed) if (self.index) |index| for (self.changes[0..self.change_count]) |change| index.set(change.row, change.previous);
    }
    fn complete(ptr: *anyopaque, probes: [2]*editing.PreparedProbe) !void {
        const self: *Transaction = @ptrCast(@alignCast(ptr));
        if (self.mark_buffers == null) return self.state.validatePreparedAction();
        const buffers = self.mark_buffers.?;
        const details: ?*const intraline.Result = if (self.snapshot.projected) if (self.display.?.details) |*value| value else null else null;
        var marks: Marks = .{ .serial = if (details != null) self.snapshot.serial else 0, .versions = .{ try probes[0].projectionVersion(), try probes[1].projectionVersion() } };
        for (probes, &self.snapshot.revisions) |probe, *revision| revision.* = try probe.revision();
        std.mem.swap([]IntralineMark, &marks.storage, &buffers.storage);
        self.marks = marks;
        if (details) |value| try collectMarks(self.state, self.snapshot, value, probes, &self.marks.?, buffers.scratch);
        try self.state.validatePreparedAction();
    }
    fn build(ptr: *anyopaque, probes: [2]*editing.LayoutProbe) !editing.PairProjection {
        const self: *Transaction = @ptrCast(@alignCast(ptr));
        if (self.display == null) return .{ .plans = @splat(null) };
        const index = self.index.?;
        if (index.heights.len == 0) self.anchor = .{} else self.anchor.row = @min(self.anchor.row, index.heights.len - 1);
        var row = self.anchor.row;
        var y: f64 = -@as(f64, @floatFromInt(self.anchor.intra)) / canonical_units;
        while (row < index.heights.len and y < self.snapshot.bounds.height) : (row += 1) {
            if (self.snapshot.count == self.state.limits.visible_rows) return error.VisibleRowCapacityExceeded;
            const mapped = index.row(row);
            var height: f64 = 0;
            if (mapped.a) |line| height = @max(height, (try probes[0].paragraph(line)).height);
            if (mapped.b) |line| height = @max(height, (try probes[1].paragraph(line)).height);
            if (!std.math.isFinite(height) or height <= 0 or height > 1000000) return error.InvalidHeight;
            const row_ticks: u64 = @intFromFloat(@ceil(height * ix.units));
            self.changes[self.change_count] = .{ .row = row, .previous = index.heights[row] };
            self.change_count += 1;
            index.set(row, row_ticks);
            if (row == self.anchor.row) {
                self.anchor.intra = @min(self.anchor.intra, (@as(u128, row_ticks) << canonical_shift) - 1);
                y = -@as(f64, @floatFromInt(self.anchor.intra)) / canonical_units;
            }
            const actual = ix.dip(row_ticks);
            self.snapshot.rows[self.snapshot.count] = .{ .index = row, .a = mapped.a, .b = mapped.b, .hunk = mapped.hunk, .y = @floatCast(y), .height = @floatCast(actual) };
            self.snapshot.count += 1;
            y += actual;
        }
        var anchors: [2]editing.ProjectionAnchor = undefined;
        for (probes, 0..) |probe, side| {
            var placements: std.ArrayList(editing.projection.Placement) = .empty;
            defer placements.deinit(self.state.budget.allocator());
            const source_lines = try probe.lineCount();
            for (index.segments[0..index.segment_count]) |segment| {
                const count = if (side == 0) segment.count_a else segment.count_b;
                const first = if (side == 0) segment.a else segment.b;
                if (count == segment.count) continue;
                const gap = ix.dip(index.prefix(segment.first + segment.count) - index.prefix(segment.first + count));
                const next = first + count;
                if (next < source_lines) try placements.append(self.state.budget.allocator(), .{ .line = next, .gap_before = gap }) else {
                    const last = source_lines - 1;
                    const aligned = sourceRow(index, side, last) orelse return error.InvalidResult;
                    try placements.append(self.state.budget.allocator(), .{ .line = last, .minimum_height = ix.dip(index.heights[aligned]) + gap });
                }
            }
            for (self.snapshot.rows[0..self.snapshot.count]) |visible| {
                const source = if (side == 0) visible.a else visible.b;
                if (source) |line| try placements.append(self.state.budget.allocator(), .{ .line = line, .minimum_height = ix.dip(index.heights[visible.index]) });
            }
            std.mem.sort(editing.projection.Placement, placements.items, {}, struct {
                fn less(_: void, a: editing.projection.Placement, b: editing.projection.Placement) bool {
                    return a.line < b.line;
                }
            }.less);
            var count: usize = 0;
            for (placements.items) |placement| {
                if (count != 0 and placements.items[count - 1].line == placement.line) {
                    placements.items[count - 1].gap_before += placement.gap_before;
                    placements.items[count - 1].minimum_height = @max(placements.items[count - 1].minimum_height, placement.minimum_height);
                } else {
                    placements.items[count] = placement;
                    count += 1;
                }
            }
            const records = placements.items[0..count];
            if (self.state.plans[side]) |old| {
                if (try old.current() and matches(old, records)) self.plans[side] = old;
            }
            if (self.plans[side] == null) {
                self.plans[side] = try editing.ProjectionPlan.create(self.state.budget.allocator(), try probe.sourceDocument(), records, .{ .entries = self.state.limits.plan_entries, .bytes = @min(self.state.limits.bytes, 64 * 1024 * 1024) });
                self.created[side] = true;
            }
            anchors[side] = try sourceAnchor(index, side, source_lines, self.anchor, records);
        }
        return .{ .plans = self.plans, .anchors = anchors };
    }
};
fn matches(plan: *const editing.ProjectionPlan, records: []const editing.projection.Placement) bool {
    if (plan.records.len != records.len) return false;
    for (plan.records, records) |record, placement| if (record.line != placement.line or record.gap != ticks(placement.gap_before) or record.minimum != ticks(placement.minimum_height)) return false;
    return true;
}
fn ticks(value: f64) u128 {
    return @as(u128, @intFromFloat(@ceil(value * 64))) << canonical_shift;
}
fn sourceRow(index: *const ix.Index, side: usize, line: usize) ?usize {
    var low: usize = 0;
    var high = index.segment_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const first = if (side == 0) index.segments[middle].a else index.segments[middle].b;
        if (first <= line) low = middle + 1 else high = middle;
    }
    if (low == 0) return null;
    const segment = index.segments[low - 1];
    const first = if (side == 0) segment.a else segment.b;
    const count = if (side == 0) segment.count_a else segment.count_b;
    return if (line - first < count) segment.first + line - first else null;
}
fn sourceAnchor(index: *const ix.Index, side: usize, source_lines: usize, anchor: Anchor, records: []const editing.projection.Placement) !editing.ProjectionAnchor {
    if (index.heights.len == 0) return .{ .line = 0 };
    const mapped = index.row(anchor.row);
    if (if (side == 0) mapped.a else mapped.b) |line| {
        return .{ .line = line, .intra_ticks = gapBefore(records, line) + anchor.intra };
    }
    var line: usize = 0;
    for (index.segments[0..index.segment_count]) |segment| {
        if (anchor.row < segment.first or anchor.row >= segment.first + segment.count) continue;
        line = (if (side == 0) segment.a else segment.b) + (if (side == 0) segment.count_a else segment.count_b);
        break;
    }
    if (line < source_lines) {
        const target = sourceRow(index, side, line) orelse index.heights.len;
        const remaining = @as(u128, index.prefix(target) - index.prefix(anchor.row)) << canonical_shift;
        const gap = gapBefore(records, line);
        if (gap < remaining) return error.InvalidProjection;
        return .{ .line = line, .intra_ticks = gap - remaining + anchor.intra };
    }
    const last = source_lines - 1;
    const first = sourceRow(index, side, last) orelse return error.InvalidResult;
    return .{ .line = last, .intra_ticks = gapBefore(records, last) + (@as(u128, index.prefix(anchor.row) - index.prefix(first)) << canonical_shift) + anchor.intra };
}
fn gapBefore(records: []const editing.projection.Placement, line: usize) u128 {
    for (records) |record| if (record.line == line) return ticks(record.gap_before);
    return 0;
}

test "source anchors preserve insertion gaps, trailing padding and EOF caret rows" {
    const diff = @import("ziggurat_document_diff");
    var result: diff.Result = .{ .allocator = std.testing.allocator, .storage = &.{}, .hunks = &.{.{ .a = .{ .lines = .{ .start = 1, .end = 1 }, .bytes = .{ .start = 2, .end = 2 } }, .b = .{ .lines = .{ .start = 1, .end = 4 }, .bytes = .{ .start = 2, .end = 8 } } }}, .a = .{ .revision = 1, .text_version = 1, .bytes = 4 }, .b = .{ .revision = 1, .text_version = 1, .bytes = 10 }, .stats = .{ .lines_a = 2, .lines_b = 5 } };
    var index = try ix.Index.create(std.testing.allocator, &result, 100, 10000, 20);
    defer index.close();
    const placements: []const editing.projection.Placement = &.{.{ .line = 1, .gap_before = 60 }};
    try std.testing.expectEqual(editing.ProjectionAnchor{ .line = 1, .intra_ticks = ticks(25) }, try sourceAnchor(&index, 0, 2, .{ .row = 2, .intra = ticks(5) }, placements));
    try std.testing.expectEqual(editing.ProjectionAnchor{ .line = 1, .intra_ticks = ticks(60) }, try sourceAnchor(&index, 0, 2, .{ .row = 4 }, placements));
    try std.testing.expectEqual(editing.ProjectionAnchor{ .line = 2, .intra_ticks = ticks(5) }, try sourceAnchor(&index, 1, 5, .{ .row = 2, .intra = ticks(5) }, &.{}));
    for (0..index.heights.len) |row| {
        const mapped = index.row(row);
        for ([_]?usize{ mapped.a, mapped.b }, 0..) |line, side| if (line) |source| try std.testing.expectEqual(row, sourceRow(&index, side, source).?);
    }
    result.hunks = &.{.{ .a = .{ .lines = .{ .start = 2, .end = 2 }, .bytes = .{ .start = 4, .end = 4 } }, .b = .{ .lines = .{ .start = 2, .end = 5 }, .bytes = .{ .start = 4, .end = 10 } } }};
    var tail = try ix.Index.create(std.testing.allocator, &result, 100, 10000, 20);
    defer tail.close();
    try std.testing.expectEqual(editing.ProjectionAnchor{ .line = 1, .intra_ticks = ticks(45) }, try sourceAnchor(&tail, 0, 2, .{ .row = 3, .intra = ticks(5) }, &.{.{ .line = 1, .minimum_height = 80 }}));
    try std.testing.expectEqual(editing.ProjectionAnchor{ .line = 2, .intra_ticks = ticks(25) }, try sourceAnchor(&tail, 0, 3, .{ .row = 3, .intra = ticks(5) }, &.{.{ .line = 2, .gap_before = 60 }}));
    var empty_result = result;
    empty_result.hunks = &.{};
    empty_result.stats.lines_a = 0;
    empty_result.stats.lines_b = 0;
    var empty = try ix.Index.create(std.testing.allocator, &empty_result, 100, 10000, 20);
    defer empty.close();
    try std.testing.expectEqual(editing.ProjectionAnchor{ .line = 0 }, try sourceAnchor(&empty, 0, 1, .{}, &.{}));
}
