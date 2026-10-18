const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const b = @import("broker.zig");
const r = @import("results.zig");
const snippets = @import("snippet.zig");
const details = @import("completion_details.zig");
pub const CompletionDetailsOptions = details.Options;

/// Resolver/context/cancellation are borrowed through Presenter.close. Values
/// are captured only while explicitly accepting a snippet; draw never calls it.
pub const SnippetPolicy = struct { parse: snippets.ParseLimits = .{}, session: snippets.Limits = .{}, expansion: snippets.ParseOptions = .{} };
/// A returned outcome means the text transaction committed. Later layout or
/// foreign disposal cannot turn it into a retryable text insertion failure.
pub const CompletionOutcome = struct {
    edit: editing.EditResult,
    committed_revision: u64,
    revision: u64,
    stale_after_commit: bool,
    snippet_active: bool,
    layout_error: ?anyerror = null,
};
/// Value identity only. It owns no Presenter pointer or asynchronous callback.
pub const CompletionChoice = struct { presenter_id: u64, selection: u64, popup: u64, ticket: b.Ticket, display_generation: u64, index: usize };
pub const RefinementOutcome = struct { published: bool = true, stale_after_commit: bool = false };
var next_resolution_id: std.atomic.Value(u64) = .init(1);
fn resolutionIdentity() !u64 {
    var id = next_resolution_id.load(.acquire);
    while (true) {
        if (id == std.math.maxInt(u64)) return error.IdExhausted;
        id = next_resolution_id.cmpxchgWeak(id, id + 1, .acq_rel, .acquire) orelse return id;
    }
}
/// Immediate owner-only scope, never stored in a worker or delivery. The
/// Window/Adapter and Presenter survive all result publication/foreign frees.
pub const CompletionRefinement = struct {
    presenter: *Presenter,
    choice: CompletionChoice,
    input: editing.NativeInputScope,
    live: bool = true,
    pub fn apply(self: *CompletionRefinement, owned: *r.OwnedResult) !RefinementOutcome {
        if (!self.live) return error.ScopeClosed;
        const presenter = self.presenter;
        if (presenter.owner != std.Thread.getCurrentId()) return error.WrongThread;
        try presenter.validateChoice(self.choice);
        const keep_rows = presenter.details_options != null;
        const projection = presenter.view.?.projection_version;
        const adapter_version = presenter.view.?.adapter_version;
        const expected_display = std.math.add(u64, self.choice.display_generation, 1) catch return error.IdExhausted;
        try presenter.broker.refineCompletion(self.choice.ticket, self.choice.display_generation, self.choice.index, owned);
        presenter.required = true;
        presenter.available() catch return .{ .stale_after_commit = true };
        if (presenter.window.isClosed() or (presenter.broker.document.version() catch return .{ .stale_after_commit = true }) != self.choice.ticket.revision) return .{ .stale_after_commit = true };
        var gate = presenter.adapter.beginNativeInput(presenter.window) catch return .{ .stale_after_commit = true };
        gate.end();
        if (keep_rows and presenter.broker.display_generation == expected_display and
            (presenter.adapter.projectionVersion() catch return .{ .stale_after_commit = true }) == projection and
            (presenter.adapter.viewVersion() catch return .{ .stale_after_commit = true }) == adapter_version)
        {
            // refineCompletion validates unchanged label/edit/order/other
            // metadata and publishes exactly this one display generation.
            // Never adopt an unrelated later generation into cached rows.
            presenter.view.?.broker_version = expected_display;
            presenter.required = false;
            presenter.details_required = true;
        }
        return .{};
    }
    pub fn end(self: *CompletionRefinement) void {
        if (!self.live) return;
        std.debug.assert(self.presenter.owner == std.Thread.getCurrentId());
        self.live = false;
        self.presenter.busy = false;
        self.input.end(); // Can close/free the entire host. No later self access.
    }
};

pub const Limits = struct {
    rectangles: usize = 1024,
    popup_rows: usize = 8,
    popup_text_bytes: usize = 4096,
    /// Includes old + candidate descriptors and conservatively reserved text
    /// layout/coverage storage. Native engine internals have their own limits.
    bytes: usize = 96 * 1024 * 1024,
    prepared: t.PrepareLimits = .{ .pixels = 256 * 1024, .bytes = 2 * 1024 * 1024 },
};
pub const Appearance = struct {
    editor: editing.Colors = .{},
    popup: u32 = 0xf3f5f8,
    selected: u32 = 0xd4e5ff,
    popup_text: ui.Color = ui.Color.rgb(0x17243a),
    err: u32 = 0xd52b32,
    warning: u32 = 0xa36a00,
    info: u32 = 0x3269ab,
    hint: u32 = 0x707070,
};
pub const OverlayInfo = struct { diagnostics: usize, completion_rows: usize, first_completion: usize, selected_completion: usize, hover: bool, popup: ?ui.Rect, popup_rows: [8]ui.Rect, details: ?ui.Rect = null };
const Mark = struct { rect: ui.Rect, severity: r.Severity };
const Text = struct {
    layout: *t.Layout,
    prepared: *t.Prepared,
    rect: ui.Rect,
    origin: ui.layout.Point,
    fn close(self: Text) void {
        self.prepared.close() catch unreachable;
        self.layout.close() catch unreachable;
    }
};
const DetailsCandidate = struct {
    text: ?Text = null,
    reserved: usize = 0,
    fn close(self: *DetailsCandidate) void {
        if (self.text) |item| item.close();
        self.text = null;
    }
};
const PointerRoute = enum { none, editor, details };
const View = struct {
    revision: u64,
    broker_version: u64,
    adapter_version: u64,
    projection_version: u64,
    bounds: ui.Rect,
    scale: f32,
    marks: []Mark,
    mark_count: usize = 0,
    text: [8]?Text = @splat(null),
    count: usize = 0,
    popup: ?ui.Rect = null,
    completion: ?b.Ticket = null,
    first: usize = 0,
    hover: bool = false,
    reserved: usize,
    details_text: ?Text = null,
    details_reserved: usize = 0,
    fn ensureUnused(self: *const View) !void {
        for (self.text[0..self.count]) |item| try item.?.prepared.ensureUnused();
        if (self.details_text) |item| try item.prepared.ensureUnused();
    }
    fn close(self: *View, allocator: std.mem.Allocator) void {
        for (self.text[0..self.count]) |item| item.?.close();
        if (self.details_text) |item| item.close();
        allocator.free(self.marks);
    }
};

/// Optional owner-thread presentation layer. Document remains the only text,
/// selection and undo owner. Host binds the existing Adapter and forwards input
/// once through handleEvent. prepare is explicit update work; draw only replays.
/// Window/App/Engine/allocators cover its lifetime. Broker and Adapter are pinned
/// against close, but direct Adapter mutations still require another prepare.
pub const Presenter = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    broker: *b.Broker,
    adapter: *editing.Adapter,
    engine: *t.Engine,
    window: z.Window,
    limits: Limits,
    busy: bool = false,
    view: ?View = null,
    selected: usize = 0,
    selected_serial: u64 = 0,
    dismissed_completion: u64 = 0,
    dismissed_hover: u64 = 0,
    required: bool = true,
    peak_reserved: usize = @sizeOf(Presenter),
    snippet_policy: ?SnippetPolicy = null,
    snippet_session: ?*snippets.Session = null,
    snippet_template: ?*snippets.Template = null,
    snippet_generation: u64 = 0,
    last_acceptance: ?CompletionOutcome = null,
    last_layout_error: ?anyerror = null,
    resolution_id: u64 = 0,
    selection_generation: u64 = 0,
    popup_generation: u64 = 0,
    details_options: ?CompletionDetailsOptions = null,
    details_required: bool = false,
    pointer_route: PointerRoute = .none,

    pub fn create(allocator: std.mem.Allocator, broker: *b.Broker, adapter: *editing.Adapter, engine: *t.Engine, window: z.Window, limits: Limits) !*Presenter {
        if (broker.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (window.isClosed() or window.app.phase == .stopping or window.app.phase == .stopped or broker.stopping) return error.Closed;
        if (limits.rectangles == 0 or limits.rectangles > 16384 or limits.popup_rows == 0 or limits.popup_rows > 8 or limits.popup_text_bytes == 0 or limits.popup_text_bytes > 65536 or limits.bytes > 1024 * 1024 * 1024 or limits.bytes < @sizeOf(Presenter) or limits.prepared.pixels == 0 or limits.prepared.pixels > 16 * 1024 * 1024 or limits.prepared.bytes == 0 or limits.prepared.bytes > 64 * 1024 * 1024) return error.InvalidLimits;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        _ = try engine.lastNativeError();
        if (try adapter.sourceDocument() != broker.document) return error.ForeignDocument;
        try broker.retainClient();
        errdefer broker.releaseClient() catch unreachable;
        try adapter.retainClient();
        errdefer adapter.releaseClient() catch unreachable;
        const self = try allocator.create(Presenter);
        errdefer allocator.destroy(self);
        if (window.isClosed() or window.app.phase == .stopping or window.app.phase == .stopped or broker.stopping) return error.Closed;
        self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .broker = broker, .adapter = adapter, .engine = engine, .window = window, .limits = limits };
        return self;
    }
    fn check(self: *const Presenter) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.busy) return error.Busy;
    }
    fn available(self: *const Presenter) !void {
        if (self.window.isClosed() or self.window.app.phase == .stopping or self.window.app.phase == .stopped or self.broker.stopping) return error.Closed;
    }
    /// Stores only a bounded value policy. Native text is prepared explicitly;
    /// this neither fetches metadata nor enables completion refinement.
    pub fn enableCompletionDetails(self: *Presenter, options: CompletionDetailsOptions) !void {
        try self.check();
        try self.available();
        if (self.details_options != null) return error.AlreadyEnabled;
        try options.validate();
        self.details_options = options;
        self.details_required = true;
    }
    /// No allocation, process, callback registration, or automatic request.
    pub fn enableCompletionRefinement(self: *Presenter) !void {
        try self.check();
        try self.available();
        if (self.resolution_id != 0) return error.AlreadyEnabled;
        self.resolution_id = try resolutionIdentity();
    }
    pub fn completionChoice(self: *Presenter) !CompletionChoice {
        try self.check();
        if (self.resolution_id == 0) return error.RefinementDisabled;
        const view = self.view orelse return error.LayoutRequired;
        _ = try self.current(view.bounds, view.scale);
        const ticket = view.completion orelse return error.NoCompletion;
        if (view.count == 0 or ticket.serial != self.selected_serial or self.dismissed_completion == ticket.serial) return error.NoCompletion;
        if (self.window.isClosed()) return error.Closed;
        if (try self.broker.document.composition() != null) return error.CompositionActive;
        return .{ .presenter_id = self.resolution_id, .selection = self.selection_generation, .popup = self.popup_generation, .ticket = ticket, .display_generation = self.broker.display_generation, .index = self.selected };
    }
    fn validateChoice(self: *Presenter, choice: CompletionChoice) !void {
        // Caller already owns the Presenter gate; no recursive check/lock.
        if (self.resolution_id == 0 or self.resolution_id != choice.presenter_id) return error.ForeignChoice;
        try self.available();
        const view = self.view orelse return error.StaleChoice;
        _ = self.current(view.bounds, view.scale) catch return error.StaleChoice;
        if (self.selection_generation != choice.selection or self.popup_generation != choice.popup or self.broker.display_generation != choice.display_generation or self.selected != choice.index or view.completion == null or !std.meta.eql(view.completion.?, choice.ticket) or self.dismissed_completion == choice.ticket.serial) return error.StaleChoice;
        if (try self.broker.document.composition() != null) return error.CompositionActive;
    }
    pub fn beginCompletionRefinement(self: *Presenter, choice: CompletionChoice) !CompletionRefinement {
        try self.check();
        try self.validateChoice(choice);
        const input = try self.adapter.beginNativeInput(self.window);
        self.busy = true;
        return .{ .presenter = self, .choice = choice, .input = input };
    }
    /// Explicit update-phase allocation; plain presenters never create a
    /// Session or parse a template. Presenter owns this Session through close.
    pub fn enableSnippets(self: *Presenter, policy: SnippetPolicy) !void {
        try self.check();
        try self.available();
        if (self.snippet_session != null) return error.SnippetsEnabled;
        try policy.parse.validate();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        const session = try snippets.Session.create(self.allocator, self.adapter, policy.session);
        errdefer session.close() catch unreachable;
        try session.retainClient();
        errdefer session.releaseClient() catch unreachable;
        try self.available();
        self.snippet_session = session;
        self.snippet_policy = policy;
    }
    pub fn snippetStatus(self: *Presenter) !snippets.Status {
        try self.check();
        const scope = self.window.app.beginTeardownCallback();
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        try self.observeSnippet();
        return (self.snippet_session orelse return error.SnippetsDisabled).status();
    }
    pub fn lastAcceptance(self: *const Presenter) !?CompletionOutcome {
        try self.check();
        return self.last_acceptance;
    }
    pub fn lastLayoutError(self: *const Presenter) !?anyerror {
        try self.check();
        return self.last_layout_error;
    }
    fn releaseRetiredTemplate(self: *Presenter) void {
        if (self.snippet_template) |template| {
            std.debug.assert(!(self.snippet_session.?.status() catch unreachable).active);
            self.snippet_template = null;
            template.close() catch unreachable;
        }
    }
    fn cancelSnippetInner(self: *Presenter) void {
        if (self.snippet_session) |session| session.cancel() catch unreachable;
        self.releaseRetiredTemplate();
    }
    fn observeSnippet(self: *Presenter) !void {
        const session = self.snippet_session orelse return;
        const status = try session.status();
        if (status.active and (self.broker.stopping or self.snippet_generation != self.broker.invalidation_generation or status.revision != try self.broker.document.version() or try self.broker.document.composition() != null)) try session.cancel();
        if (!(try session.status()).active) self.releaseRetiredTemplate();
    }
    pub fn cancelSnippet(self: *Presenter) !void {
        try self.check();
        const scope = self.window.app.beginTeardownCallback();
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        self.cancelSnippetInner();
    }
    pub fn chooseSnippet(self: *Presenter, index: usize) !snippets.Outcome {
        try self.check();
        try self.available();
        var scope = try self.adapter.beginNativeInput(self.window);
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        try self.observeSnippet();
        const outcome = try (self.snippet_session orelse return error.SnippetsDisabled).choose(index);
        self.required = true;
        if (!outcome.active) self.releaseRetiredTemplate();
        return outcome;
    }
    pub fn close(self: *Presenter) !void {
        try self.check();
        const scope = self.window.app.beginTeardownCallback();
        defer scope.end();
        if (self.view) |*view| try view.ensureUnused();
        try self.adapter.ensureUnused();
        _ = try self.adapter.sourceDocument();
        const borrow = try self.broker.borrowForTeardown();
        defer borrow.end();
        self.busy = true;
        self.cancelSnippetInner();
        if (self.snippet_session) |session| {
            self.snippet_session = null;
            session.releaseClient() catch unreachable;
            session.close() catch unreachable;
        }
        if (self.view) |*view| view.close(self.allocator);
        const adapter = self.adapter;
        const allocator = self.allocator;
        borrow.releaseClient() catch unreachable;
        // The containing allocator can reenter on the final shell free. Its
        // Adapter client must cover that callback and the complete destruction.
        allocator.destroy(self);
        adapter.releaseClient() catch unreachable;
    }
    pub fn prepare(self: *Presenter, bounds: ui.Rect, parameters: editing.Parameters) !void {
        try self.check();
        try self.available();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        self.prepareInner(bounds, parameters) catch |err| {
            self.last_layout_error = err;
            return err;
        };
        self.last_layout_error = null;
    }
    fn prepareInner(self: *Presenter, bounds: ui.Rect, parameters: editing.Parameters) !void {
        try self.available();
        if (self.view) |*view| try view.ensureUnused();
        var reusable_rows = false;
        errdefer if (!reusable_rows) {
            self.required = true;
        };
        try self.observeSnippet();
        try self.broker.observe();
        _ = try self.adapter.prepare(bounds, parameters);
        try self.available();
        const borrow = try self.broker.borrow();
        defer borrow.end();
        const revision = try self.broker.document.version();
        const adapter_version = try self.adapter.viewVersion();
        const projection_version = try self.adapter.projectionVersion();
        const broker_version = self.broker.display_generation;
        if (!self.required) if (self.view) |*view| if (view.projection_version == projection_version and view.broker_version == broker_version) {
            reusable_rows = true;
            if (self.details_required) self.prepareSelectedDetails(view, borrow, parameters, revision, adapter_version) catch |err| {
                if (err == error.Closed or err == error.StaleRevision) self.required = true;
                return err;
            };
            view.revision = revision;
            view.adapter_version = adapter_version;
            return;
        };
        const next_popup = if (self.resolution_id != 0) std.math.add(u64, self.popup_generation, 1) catch return error.IdExhausted else 0;
        const previous = if (self.view) |view| view.reserved else 0;
        const base = @sizeOf(View) + self.limits.rectangles * (@sizeOf(Mark) + @sizeOf(t.Rect));
        if (base > self.limits.bytes -| (@sizeOf(Presenter) + previous)) return error.CapacityExceeded;
        self.peak_reserved = @max(self.peak_reserved, @sizeOf(Presenter) + previous + base);
        var candidate: View = .{ .revision = revision, .broker_version = broker_version, .adapter_version = adapter_version, .projection_version = projection_version, .bounds = bounds, .scale = parameters.scale, .marks = try self.allocator.alloc(Mark, self.limits.rectangles), .reserved = base };
        defer candidate.close(self.allocator);
        {
            const scratch = try self.allocator.alloc(t.Rect, self.limits.rectangles);
            defer self.allocator.free(scratch);
            if (try borrow.display(.diagnostics)) |display| for (display.data.diagnostics) |item| {
                var rects = try self.adapter.rangeRects(revision, item.range, scratch);
                if (item.range.start == item.range.end) if (try self.adapter.positionRect(revision, item.range.start, .downstream)) |rect| {
                    scratch[0] = rect;
                    rects = scratch[0..1];
                };
                if (rects.len > candidate.marks.len - candidate.mark_count) return error.RectangleCapacityExceeded;
                for (rects) |rect| {
                    const height = @min(rect.height, 2 / parameters.scale);
                    candidate.marks[candidate.mark_count] = .{ .rect = .{ .x = rect.x, .y = rect.y + rect.height - height, .width = @max(2 / parameters.scale, rect.width), .height = height }, .severity = item.severity };
                    candidate.mark_count += 1;
                }
            };
        }
        if (try borrow.display(.completion)) |display| if (display.ticket.serial != self.dismissed_completion and display.data.completion.len != 0) {
            const selected = if (self.selected_serial == display.ticket.serial) @min(self.selected, display.data.completion.len - 1) else 0;
            if (try self.adapter.positionRect(revision, display.position, .downstream)) |anchor| {
                const width = @min(bounds.width, 360);
                const row_height = @max(18, parameters.font.size * 1.6);
                const rows = @min(self.limits.popup_rows, @as(usize, @intFromFloat(@floor(bounds.height / row_height))), display.data.completion.len);
                if (rows != 0) {
                    candidate.first = selected -| (rows - 1);
                    candidate.completion = display.ticket;
                    const box = popup(bounds, anchor, width, row_height * @as(f32, @floatFromInt(rows)));
                    candidate.popup = box;
                    for (display.data.completion[candidate.first..][0..rows], 0..) |item, index| {
                        const rect: ui.Rect = .{ .x = box.x, .y = box.y + row_height * @as(f32, @floatFromInt(index)), .width = box.width, .height = row_height };
                        try self.addText(&candidate, item.label, rect, parameters, false, previous);
                    }
                    const extra = try self.buildDetails(box, bounds, display.data.completion[selected], parameters, previous + candidate.reserved);
                    candidate.details_text = extra.text;
                    candidate.details_reserved = extra.reserved;
                    candidate.reserved += extra.reserved;
                }
            }
        };
        if (candidate.count == 0) if (try borrow.display(.hover)) |display| if (display.ticket.serial != self.dismissed_hover and display.data.hover.text.len != 0) {
            if (try self.adapter.positionRect(revision, display.data.hover.range.start, .downstream)) |anchor| {
                const box = popup(bounds, anchor, @min(bounds.width, 360), @min(bounds.height, 160));
                candidate.popup = box;
                candidate.hover = true;
                try self.addText(&candidate, display.data.hover.text, box, parameters, true, previous);
            }
        };
        // All foreign allocation/layout work has finished. Direct host edits or
        // view changes from an allocator callback invalidate this candidate.
        try self.available();
        if (revision != try self.broker.document.version() or adapter_version != try self.adapter.viewVersion()) return error.StaleRevision;
        const old = self.view;
        self.view = candidate;
        self.popup_generation = next_popup;
        candidate.marks = &.{};
        candidate.count = 0;
        candidate.details_text = null;
        self.required = false;
        self.details_required = false;
        if (self.view.?.completion) |ticket| {
            const display = (try borrow.display(.completion)).?;
            if (self.selected_serial != ticket.serial) self.selected = 0;
            self.selected = @min(self.selected, display.data.completion.len - 1);
            self.selected_serial = ticket.serial;
        }
        if (old) |value| {
            var previous_view = value;
            previous_view.close(self.allocator);
        }
        // Destruction can reenter host allocation hooks too. Never advertise a
        // stale candidate as current after that final release.
        try self.available();
        if (revision != try self.broker.document.version() or adapter_version != try self.adapter.viewVersion()) {
            self.required = true;
            return error.StaleRevision;
        }
    }
    fn buildDetails(self: *Presenter, box: ui.Rect, bounds: ui.Rect, item: r.Completion, parameters: editing.Parameters, retained: usize) !DetailsCandidate {
        const options = self.details_options orelse return .{};
        const length = try details.sourceLength(item.detail, item.documentation, options.text_bytes);
        if (length == 0) return .{};
        const rect = try details.place(bounds, box, options) orelse return .{};
        // A single candidate owns its text snapshot; the bounded temporary
        // composition coexists with it and the complete old view.
        const reservation = @sizeOf(Text) + 4 * 1024 * 1024 + options.prepared.bytes + length;
        if (retained > self.limits.bytes - @sizeOf(Presenter) or reservation > self.limits.bytes - @sizeOf(Presenter) - retained) return error.CapacityExceeded;
        self.peak_reserved = @max(self.peak_reserved, @sizeOf(Presenter) + retained + reservation);
        const source = try self.allocator.alloc(u8, length);
        defer self.allocator.free(source);
        try self.available();
        const text = try details.writeSource(item.detail, item.documentation, source);
        var font = parameters.font;
        font.width = rect.width - 8;
        font.wrap = .word_character;
        const layout = try self.engine.layoutAllocated(self.allocator, text, font);
        errdefer layout.close() catch unreachable;
        try self.available();
        const prepared = try layout.prepare(parameters.scale, .{ .limits = options.prepared, .viewport = .{ .x = 0, .y = 0, .width = rect.width - 8, .height = rect.height - 4 } });
        errdefer prepared.close() catch unreachable;
        try self.available();
        return .{ .text = .{ .layout = layout, .prepared = prepared, .rect = rect, .origin = .{ .x = rect.x + 4, .y = rect.y + 2 } }, .reserved = reservation };
    }
    /// Replaces only details. Row/diagnostic owners never copy or move during
    /// same-page selection; a failed candidate leaves them ready for retry.
    fn prepareSelectedDetails(self: *Presenter, view: *View, borrow: b.Borrow, parameters: editing.Parameters, revision: u64, adapter_version: u64) !void {
        errdefer self.details_required = true;
        var candidate: DetailsCandidate = .{};
        defer candidate.close();
        if (view.completion) |ticket| {
            const display = try borrow.display(.completion) orelse return error.StaleRevision;
            if (!std.meta.eql(display.ticket, ticket) or self.selected >= display.data.completion.len) return error.StaleRevision;
            candidate = try self.buildDetails(view.popup.?, view.bounds, display.data.completion[self.selected], parameters, view.reserved);
        }
        try self.available();
        if (revision != try self.broker.document.version() or adapter_version != try self.adapter.viewVersion()) return error.StaleRevision;
        const old = view.details_text;
        view.reserved = view.reserved - view.details_reserved + candidate.reserved;
        view.details_reserved = candidate.reserved;
        view.details_text = candidate.text;
        candidate.text = null;
        self.details_required = false;
        if (old) |item| item.close();
        // The old native owners' final allocator callbacks can mutate/close.
        try self.available();
        if (revision != try self.broker.document.version() or adapter_version != try self.adapter.viewVersion()) return error.StaleRevision;
    }
    fn addText(self: *Presenter, candidate: *View, text: []const u8, rect: ui.Rect, parameters: editing.Parameters, wrap: bool, old_bytes: usize) !void {
        if (text.len > self.limits.popup_text_bytes) return error.CapacityExceeded;
        // Engine construction has a 4MiB owning limit. Reserve its full bound
        // plus the explicit preparation plane before doing native work.
        const reservation = 4 * 1024 * 1024 + self.limits.prepared.bytes;
        const total = @sizeOf(Presenter) + old_bytes + candidate.reserved;
        if (reservation > self.limits.bytes -| total) return error.CapacityExceeded;
        candidate.reserved += reservation;
        self.peak_reserved = @max(self.peak_reserved, total + reservation);
        var font = parameters.font;
        font.width = @max(1, rect.width - 8);
        font.wrap = if (wrap) .word_character else .none;
        const layout = try self.engine.layout(text, font);
        errdefer layout.close() catch unreachable;
        try self.available();
        const prepared = try layout.prepare(parameters.scale, .{ .limits = self.limits.prepared, .viewport = .{ .x = 0, .y = 0, .width = @max(1, rect.width - 8), .height = @max(1, rect.height - 4) } });
        errdefer prepared.close() catch unreachable;
        try self.available();
        candidate.text[candidate.count] = .{ .layout = layout, .prepared = prepared, .rect = rect, .origin = .{ .x = rect.x + 4, .y = rect.y + 2 } };
        candidate.count += 1;
    }
    fn current(self: *Presenter, bounds: ui.Rect, scale: f32) !*const View {
        try self.available();
        if (self.required or self.details_required) return error.LayoutRequired;
        const view = if (self.view) |*value| value else return error.LayoutRequired;
        if (view.revision != try self.broker.document.version() or view.broker_version != self.broker.display_generation or view.adapter_version != try self.adapter.viewVersion() or !std.meta.eql(view.bounds, bounds) or view.scale != scale) return error.LayoutRequired;
        return view;
    }
    pub fn overlayInfo(self: *Presenter) !OverlayInfo {
        try self.check();
        const view = try self.current((self.view orelse return error.LayoutRequired).bounds, self.view.?.scale);
        var info: OverlayInfo = .{ .diagnostics = view.mark_count, .completion_rows = if (view.completion != null) view.count else 0, .first_completion = view.first, .selected_completion = self.selected, .hover = view.hover, .popup = view.popup, .popup_rows = @splat(.{ .x = 0, .y = 0, .width = 0, .height = 0 }) };
        for (view.text[0..view.count], 0..) |item, index| info.popup_rows[index] = item.?.rect;
        if (view.details_text) |item| info.details = item.rect;
        return info;
    }
    pub fn draw(self: *Presenter, frame: *ui.Frame, bounds: ui.Rect, appearance: Appearance) anyerror!void {
        try self.check();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        errdefer |err| frame.failure = frame.failure orelse err;
        const view = try self.current(bounds, frame.size.scale);
        try self.adapter.draw(frame, bounds, appearance.editor);
        try frame.pushClip(bounds);
        defer frame.popClip() catch |err| {
            frame.failure = frame.failure orelse err;
        };
        for (view.marks[0..view.mark_count]) |mark| frame.rect(mark.rect, switch (mark.severity) {
            .err => appearance.err,
            .warning => appearance.warning,
            .info => appearance.info,
            .hint => appearance.hint,
        });
        if (view.popup) |box| frame.rect(box, appearance.popup);
        for (view.text[0..view.count], 0..) |item, index| {
            const text = item.?;
            if (view.completion != null and view.first + index == self.selected) frame.rect(text.rect, appearance.selected);
            try frame.pushClip(text.rect);
            defer frame.popClip() catch |err| {
                frame.failure = frame.failure orelse err;
            };
            try frame.preparedText(text.origin, try text.prepared.view(), appearance.popup_text);
        }
        if (view.details_text) |text| {
            frame.rect(text.rect, appearance.popup);
            try frame.pushClip(text.rect);
            defer frame.popClip() catch |err| {
                frame.failure = frame.failure orelse err;
            };
            try frame.preparedText(text.origin, try text.prepared.view(), appearance.popup_text);
        }
        if (frame.failure) |err| return @as(anyerror!void, err);
    }
    pub fn acceptCompletion(self: *Presenter, index: usize) !editing.EditResult {
        return (try self.acceptCompletionOutcome(index)).edit;
    }
    pub fn acceptCompletionOutcome(self: *Presenter, index: usize) !CompletionOutcome {
        try self.check();
        try self.available();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        return self.acceptInner(index);
    }
    fn acceptInner(self: *Presenter, index: usize) !CompletionOutcome {
        const view = if (self.view) |value| try self.current(value.bounds, value.scale) else return error.LayoutRequired;
        const ticket = view.completion orelse return error.NoCompletion;
        if (view.count == 0) return error.NoCompletion;
        const borrow = try self.broker.borrow();
        defer borrow.end();
        const display = try borrow.display(.completion) orelse return error.NoCompletion;
        if (display.ticket.serial != ticket.serial or display.ticket.serial == self.dismissed_completion) return error.NoCompletion;
        if (index >= display.data.completion.len) return error.InvalidCompletion;
        const item = display.data.completion[index];
        var scope = try self.adapter.beginNativeInput(self.window);
        defer scope.end();
        const stamp = std.math.add(u64, display.ticket.revision, 1) catch return error.IdExhausted;
        var outcome: CompletionOutcome = undefined;
        switch (item.insertion) {
            .plain => {
                const edit = try self.adapter.replaceMany(display.ticket.revision, item.edits);
                self.cancelSnippetInner();
                const revision = try self.broker.document.version();
                outcome = .{ .edit = .{ .changed = edit.changed, .index_required = revision != stamp or edit.index_required }, .committed_revision = stamp, .revision = revision, .stale_after_commit = revision != stamp or edit.index_required, .snippet_active = false };
            },
            .snippet => |snippet_index| {
                const session = self.snippet_session orelse return error.SnippetsDisabled;
                if ((try session.status()).active) return error.AlreadyActive;
                const template = block: {
                    var preparation = try session.beginPreparation();
                    defer preparation.end();
                    break :block try snippets.Template.parseResolved(self.allocator, item.edits[snippet_index].text, self.snippet_policy.?.parse, self.snippet_policy.?.expansion);
                };
                var released_or_transferred = false;
                defer if (!released_or_transferred) template.close() catch unreachable;
                try self.available();
                if (try self.broker.document.version() != display.ticket.revision) return error.StaleRevision;
                const result = try session.startCompletion(template, display.ticket.revision, item.edits, snippet_index);
                if (result.active) {
                    self.snippet_template = template;
                    self.snippet_generation = self.broker.invalidation_generation;
                } else template.close() catch unreachable;
                released_or_transferred = true;
                const revision = try self.broker.document.version();
                const stale = result.stale_after_commit or revision != stamp;
                if (stale and result.active) self.cancelSnippetInner();
                outcome = .{ .edit = .{ .changed = true, .index_required = stale }, .committed_revision = result.committed_revision.?, .revision = try self.broker.document.version(), .stale_after_commit = stale, .snippet_active = result.active and !stale };
            },
        }
        const after = try self.broker.document.version();
        const available_now = if (self.available()) |_| true else |_| false;
        if (outcome.stale_after_commit or after != outcome.committed_revision or !available_now) {
            if (outcome.snippet_active) self.cancelSnippetInner();
            outcome.snippet_active = false;
            outcome.stale_after_commit = true;
            outcome.edit.index_required = true;
        }
        outcome.revision = try self.broker.document.version();
        outcome.stale_after_commit = outcome.stale_after_commit or outcome.revision != outcome.committed_revision;
        self.required = true;
        self.last_layout_error = null;
        self.last_acceptance = outcome;
        return outcome;
    }
    fn prepareCommittedInput(self: *Presenter, bounds: ui.Rect, parameters: editing.Parameters, acceptance: bool) void {
        self.last_layout_error = null;
        self.prepareInner(bounds, parameters) catch |err| {
            self.last_layout_error = err;
            if (acceptance) self.last_acceptance.?.layout_error = err;
        };
        self.window.invalidate();
    }
    pub fn handleEvent(self: *Presenter, event: z.Event, bounds: ui.Rect, parameters: editing.Parameters) !bool {
        try self.check();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        const terminal_forwarded = self.details_options != null and (event == .cancel_input or (event == .focus and !event.focus));
        if (terminal_forwarded) {
            // Adapter's terminal fast path has no Document/native query. End
            // a press before metadata observation/foreign cleanup can fail.
            _ = try self.adapter.handleEvent(self.window, event, bounds, parameters);
            self.pointer_route = .none;
        }
        if (self.broker.stopping or self.window.app.phase == .stopping or self.window.app.phase == .stopped) {
            if (self.pointer_route == .editor) _ = self.adapter.handleEvent(self.window, .cancel_input, bounds, parameters) catch false;
            self.pointer_route = .none;
            self.cancelSnippetInner();
            return error.Closed;
        }
        try self.observeSnippet();
        if (self.resolution_id != 0) switch (event) {
            .key_input, .key, .pointer_down, .text_input, .text_preedit, .text_preedit_cancel, .edit_key, .focus, .cancel_input => self.selection_generation = std.math.add(u64, self.selection_generation, 1) catch return error.IdExhausted,
            else => {},
        };
        if ((event == .focus and !event.focus) or event == .cancel_input) {
            self.pointer_route = .none;
            if (try self.broker.display(.completion)) |display| self.dismissed_completion = display.ticket.serial;
            if (try self.broker.display(.hover)) |display| self.dismissed_hover = display.ticket.serial;
            self.required = true;
        }
        // A pointer sequence belongs to its press target. In particular, a
        // detail overlay must not hide the release that ends editor dragging.
        if (event == .pointer_move or event == .pointer_up) switch (self.pointer_route) {
            .none => {},
            .details => {
                if (event == .pointer_up) self.pointer_route = .none;
                return true;
            },
            .editor => {
                if (event == .pointer_up) self.pointer_route = .none;
                const consumed = try self.adapter.handleEvent(self.window, event, bounds, parameters);
                try self.prepareInner(bounds, parameters);
                return consumed;
            },
        };
        if (event == .pointer_down and self.details_options != null) {
            if (self.pointer_route == .editor) _ = try self.adapter.handleEvent(self.window, .cancel_input, bounds, parameters);
            self.pointer_route = .none;
        }
        // Native IME keeps priority; previews hide decorations without losing
        // a still-current committed-text diagnostic/hover result.
        if (try self.broker.document.composition() == null) {
            const active = self.current(bounds, parameters.scale) catch null;
            if (event == .key_input) {
                const input = event.key_input;
                if (!input.modifiers.control and !input.modifiers.alt and !input.modifiers.super and !input.modifiers.shift) {
                    if (input.key == .escape and active != null and active.?.popup != null) {
                        if (active.?.completion) |ticket| self.dismissed_completion = ticket.serial;
                        if (active.?.hover) if (try self.broker.display(.hover)) |display| {
                            self.dismissed_hover = display.ticket.serial;
                        };
                        self.required = true;
                        try self.prepareInner(bounds, parameters);
                        self.window.invalidate();
                        return true;
                    }
                    if (try self.broker.display(.completion)) |display| if (active != null and active.?.completion != null and active.?.count != 0 and active.?.completion.?.serial == display.ticket.serial and display.ticket.serial != self.dismissed_completion and display.data.completion.len != 0) {
                        if (self.selected_serial != display.ticket.serial) self.selected = 0;
                        self.selected_serial = display.ticket.serial;
                        if (input.key == .up or input.key == .down or input.key == .enter or input.key == .tab) {
                            if (input.key == .enter or input.key == .tab) {
                                _ = try self.acceptInner(self.selected);
                                self.prepareCommittedInput(bounds, parameters, true);
                                return true;
                            } else {
                                const previous_selection = self.selected;
                                self.selected = if (input.key == .up) self.selected -| 1 else @min(display.data.completion.len - 1, self.selected + 1);
                                if (self.selected >= active.?.first and self.selected < active.?.first + active.?.count) {
                                    if (self.details_options != null and self.selected != previous_selection) {
                                        self.details_required = true;
                                        self.prepareCommittedInput(bounds, parameters, false);
                                        return true;
                                    }
                                    self.window.invalidate();
                                    return true;
                                }
                                self.required = true;
                                self.prepareCommittedInput(bounds, parameters, false);
                                return true;
                            }
                        }
                    };
                }
            }
            const detail_point: ?z.Point = switch (event) {
                .pointer_down => event.pointer_down.position,
                .pointer_up => event.pointer_up.position,
                .pointer_move => event.pointer_move,
                .wheel => event.wheel.position,
                else => null,
            };
            if (detail_point) |point| if (self.current(bounds, parameters.scale)) |view| {
                if (view.details_text) |text| if (text.rect.contains(point)) {
                    if (event == .pointer_down) self.pointer_route = .details;
                    return true;
                };
            } else |_| {};
            if (event == .pointer_down) {
                if (self.current(bounds, parameters.scale)) |view| {
                    if (view.completion != null) for (view.text[0..view.count], 0..) |item, index| if (item.?.rect.contains(event.pointer_down.position)) {
                        _ = try self.acceptInner(view.first + index);
                        self.prepareCommittedInput(bounds, parameters, true);
                        return true;
                    };
                } else |_| {}
            }
        }
        if (self.snippet_session) |session| {
            if (try session.handleEvent(self.window, event)) {
                if (!(try session.status()).active) self.releaseRetiredTemplate();
                self.required = true;
                self.prepareCommittedInput(bounds, parameters, false);
                return true;
            }
            if (!(try session.status()).active) self.releaseRetiredTemplate();
        }
        if (event == .pointer_down and self.details_options != null and bounds.contains(event.pointer_down.position)) self.pointer_route = .editor;
        const consumed = if (terminal_forwarded) false else try self.adapter.handleEvent(self.window, event, bounds, parameters);
        if (event == .pointer_down and self.details_options != null and !consumed) self.pointer_route = .none;
        if (self.window.isClosed()) return error.Closed;
        try self.prepareInner(bounds, parameters);
        return consumed;
    }
};

fn popup(bounds: ui.Rect, anchor: t.Rect, width: f32, height: f32) ui.Rect {
    const below = anchor.y + anchor.height;
    return .{ .x = std.math.clamp(anchor.x, bounds.x, bounds.x + bounds.width - width), .y = std.math.clamp(if (below + height <= bounds.y + bounds.height) below else anchor.y - height, bounds.y, bounds.y + bounds.height - height), .width = width, .height = height };
}
