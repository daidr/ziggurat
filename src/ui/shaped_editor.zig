const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
pub const caret_visual = @import("ziggurat_caret");
pub const Editor = ui.editor.Editor;
pub const Rect = ui.Rect;
pub const Point = ui.layout.Point;

pub const Limits = struct {
    visual_stops: usize = 16386,
    rectangles: usize = 16384,
    prepared: t.PrepareLimits = .{},
    caret_work: usize = 1024 * 1024,
};
pub const Parameters = struct {
    font: t.Options = .{},
    scale: f32 = 1,
    /// Explicit invalidation for font catalog or other external changes.
    version: u64 = 0,
    caret_cells: bool = false,
};
pub const PaintCommand = union(enum) {
    text: struct { prepared: *const t.Prepared, origin: Point },
    selection: Rect,
    composition: Rect,
    caret: Rect,
};
pub const Surface = struct {
    context: *anyopaque,
    /// Borrow only for this draw/replay transaction. No shaping in this callback.
    paint: *const fn (*anyopaque, PaintCommand) anyerror!void,
    /// Required only by drawStyled. Block fills arrive before the text.
    paint_caret: ?*const fn (*anyopaque, caret_visual.Paint) anyerror!void = null,
};
const Stop = struct { caret: t.Caret, rect: t.Rect, line: usize };
const LineRange = struct { start: usize, end: usize };
const Geometry = struct {
    selection: []t.Rect,
    composition: []t.Rect,
    caret: t.Rect,
    source: ui.editor.Selection,
    affinity: t.Affinity,
    cells: []caret_visual.Rect = &.{},
    cells_enabled: bool = false,
    fn deinit(self: Geometry, allocator: std.mem.Allocator) void {
        allocator.free(self.selection);
        allocator.free(self.composition);
        allocator.free(self.cells);
    }
};
const Snapshot = struct {
    layout: *t.Layout,
    prepared: *t.Prepared,
    stops: []Stop,
    rows: []LineRange,
    metrics: t.Metrics,
    geometry: Geometry,
    revision: u64,
    buffer_revision: u64,
    version: u64,
    scale: f32,
    width: f32,
    height: f32,
    viewport: t.drawing.Rect,
    fn release(self: *Snapshot, allocator: std.mem.Allocator) void {
        self.prepared.close() catch unreachable;
        self.layout.close() catch unreachable;
        allocator.free(self.stops);
        allocator.free(self.rows);
        self.geometry.deinit(allocator);
    }
};
const SourceStamp = struct {
    revision: u64,
    buffer_revision: u64,
    selected: ui.editor.Selection,
    fn capture(editor: *const Editor) SourceStamp {
        return .{ .revision = editor.display_revision, .buffer_revision = editor.buffer.revision, .selected = editor.displaySelection() };
    }
    fn check(self: SourceStamp, editor: *const Editor) !void {
        if (self.revision != editor.display_revision or self.buffer_revision != editor.buffer.revision or editor.display_dirty or !std.meta.eql(self.selected, editor.displaySelection())) return error.LayoutRequired;
    }
};

/// Optional owning visual adapter. Editor.buffer remains the only document,
/// selection, preedit and undo authority. Engine and Editor outlive this object.
/// Keep this object at a stable address while callbacks borrow it.
pub const Adapter = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    editor: *Editor,
    engine: *t.Engine,
    limits: Limits,
    snapshot: ?Snapshot = null,
    affinity: t.Affinity = .downstream,
    busy: bool = false,

    pub fn init(allocator: std.mem.Allocator, editor: *Editor, engine: *t.Engine, limits: Limits) !Adapter {
        _ = try engine.lastNativeError();
        if (limits.visual_stops < 2 or limits.visual_stops > 16386 or limits.rectangles > 16384 or limits.caret_work > 64 * 1024 * 1024) return error.InvalidLimits;
        return .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .editor = editor, .engine = engine, .limits = limits };
    }
    fn enter(self: *Adapter) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.busy) return error.Busy;
        self.busy = true;
    }
    pub fn deinit(self: *Adapter) !void {
        try self.enter();
        errdefer self.busy = false;
        if (self.snapshot) |*snapshot| {
            if (try snapshot.prepared.inUse()) return error.ResourceInUse;
            snapshot.release(self.allocator);
        }
        self.* = undefined;
    }
    /// Explicit input/layout-stage work. Prepublication failure preserves the
    /// old cache. Foreign old-resource cleanup may invalidate a published
    /// snapshot: LayoutRequired then requests preparation for the new source.
    pub fn prepare(self: *Adapter, bounds: Rect, parameters: Parameters) !bool {
        try self.enter();
        defer self.busy = false;
        return self.prepareInner(bounds, parameters);
    }
    fn prepareInner(self: *Adapter, bounds: Rect, parameters: Parameters) !bool {
        try validBounds(bounds);
        if (!std.math.isFinite(parameters.scale) or parameters.scale <= 0) return error.InvalidScale;
        var font = parameters.font;
        if (font.wrap != .none) font.width = bounds.width;
        const text = self.editor.displayText();
        const stamp = SourceStamp.capture(self.editor);
        const affinity_before = self.affinity;
        if (self.snapshot) |*old| {
            if (try old.prepared.inUse()) return error.ResourceInUse;
            const rebuild = old.version != parameters.version or !sameFont(try old.layout.options(), font) or !std.mem.eql(u8, try old.layout.text(), text);
            if (!rebuild) {
                const selected = self.editor.displaySelection();
                const geometry_changed = old.revision != stamp.revision or old.buffer_revision != stamp.buffer_revision or !std.meta.eql(old.geometry.source, selected) or old.geometry.affinity != self.affinity or old.geometry.cells_enabled != parameters.caret_cells;
                const geometry = if (geometry_changed) try self.makeGeometry(old.layout, self.affinity, parameters.caret_cells) else old.geometry;
                var published = false;
                errdefer if (!published and geometry_changed) geometry.deinit(self.allocator);
                const scroll = try self.planScroll(bounds, old.metrics.bounds, geometry.caret);
                const viewport = visibleViewport(bounds, scroll);
                const coverage_changed = old.scale != parameters.scale or !std.meta.eql(old.viewport, viewport);
                const prepared = if (coverage_changed) try old.layout.prepare(parameters.scale, .{ .limits = self.limits.prepared, .viewport = viewport }) else old.prepared;
                errdefer if (!published and coverage_changed) prepared.close() catch unreachable;
                const changed = geometry_changed or coverage_changed or old.width != bounds.width or old.height != bounds.height;
                try stamp.check(self.editor);
                if (self.affinity != affinity_before) return error.LayoutRequired;
                if (try old.prepared.inUse()) return error.ResourceInUse;
                const retired_geometry = old.geometry;
                const retired_prepared = old.prepared;
                old.geometry = geometry;
                old.prepared = prepared;
                old.revision = stamp.revision;
                old.buffer_revision = stamp.buffer_revision;
                old.width = bounds.width;
                old.height = bounds.height;
                old.scale = parameters.scale;
                old.viewport = viewport;
                self.editor.scroll = scroll;
                self.editor.reveal_caret = false;
                published = true;
                if (coverage_changed) retired_prepared.close() catch unreachable;
                if (geometry_changed) retired_geometry.deinit(self.allocator);
                try stamp.check(self.editor);
                if (self.affinity != affinity_before) return error.LayoutRequired;
                return changed;
            }
        }
        var published = false;
        const shaped = try self.engine.layout(text, font);
        errdefer if (!published) shaped.close() catch unreachable;
        const metrics = try shaped.metrics();
        const lines = try shaped.lines();
        const count = try shaped.graphemeCount();
        const stop_count = try std.math.mul(usize, count + 1, 2);
        if (stop_count > self.limits.visual_stops) return error.VisualCapacityExceeded;
        const stops = try self.allocator.alloc(Stop, stop_count);
        errdefer if (!published) self.allocator.free(stops);
        const rows = try self.allocator.alloc(LineRange, lines.len);
        errdefer if (!published) self.allocator.free(rows);
        for (0..count + 1) |index| {
            const byte = try shaped.graphemeByte(index);
            for ([_]t.Affinity{ .upstream, .downstream }, 0..) |affinity, side| {
                const caret: t.Caret = .{ .byte_offset = byte, .affinity = affinity };
                const rect = try shaped.caret(caret);
                stops[index * 2 + side] = .{ .caret = caret, .rect = rect, .line = rowAt(lines, rect.y + rect.height * 0.5) };
            }
        }
        std.mem.sort(Stop, stops, {}, stopLess);
        var position: usize = 0;
        for (rows, 0..) |*row, index| {
            row.start = position;
            while (position < stops.len and stops[position].line == index) : (position += 1) {}
            row.end = position;
        }
        const geometry = try self.makeGeometry(shaped, .downstream, parameters.caret_cells);
        errdefer if (!published) geometry.deinit(self.allocator);
        const scroll = try self.planScroll(bounds, metrics.bounds, geometry.caret);
        const viewport = visibleViewport(bounds, scroll);
        const prepared = try shaped.prepare(parameters.scale, .{ .limits = self.limits.prepared, .viewport = viewport });
        errdefer if (!published) prepared.close() catch unreachable;
        const candidate: Snapshot = .{ .layout = shaped, .prepared = prepared, .stops = stops, .rows = rows, .metrics = metrics, .geometry = geometry, .revision = stamp.revision, .buffer_revision = stamp.buffer_revision, .version = parameters.version, .scale = parameters.scale, .width = bounds.width, .height = bounds.height, .viewport = viewport };
        try stamp.check(self.editor);
        if (self.affinity != affinity_before) return error.LayoutRequired;
        if (self.snapshot) |*old| if (try old.prepared.inUse()) return error.ResourceInUse;
        var retired = self.snapshot;
        self.snapshot = candidate;
        self.affinity = .downstream;
        self.editor.scroll = scroll;
        self.editor.reveal_caret = false;
        published = true;
        if (retired) |*old| old.release(self.allocator);
        try stamp.check(self.editor);
        if (self.affinity != .downstream) return error.LayoutRequired;
        return true;
    }
    fn makeGeometry(self: *Adapter, shaped: *const t.Layout, affinity: t.Affinity, cells_enabled: bool) !Geometry {
        const selected = self.editor.displaySelection();
        const range = selected.range();
        const first = try snap(shaped, range.start, false);
        const last = if (range.start == range.end) first else try snap(shaped, range.end, true);
        const selection_range: t.ByteRange = .{ .start = first, .end = last };
        const selected_count = try shaped.selectionRectCount(selection_range);
        const composition_range: t.ByteRange = if (self.editor.buffer.composition()) |preedit| .{ .start = try snap(shaped, preedit.range.start, false), .end = try snap(shaped, preedit.range.start + preedit.text.len, true) } else .{ .start = 0, .end = 0 };
        const composition_count = try shaped.selectionRectCount(composition_range);
        if (selected_count + composition_count > self.limits.rectangles) return error.RectangleCapacityExceeded;
        const selection = try self.allocator.alloc(t.Rect, selected_count);
        errdefer self.allocator.free(selection);
        const composition = try self.allocator.alloc(t.Rect, composition_count);
        errdefer self.allocator.free(composition);
        _ = try shaped.selectionRects(selection_range, selection);
        _ = try shaped.selectionRects(composition_range, composition);
        const byte = try snap(shaped, selected.caret, true);
        const native = try shaped.caret(.{ .byte_offset = byte, .affinity = affinity });
        var cells: std.ArrayList(caret_visual.Rect) = .empty;
        defer cells.deinit(self.allocator);
        if (cells_enabled) {
            const spans = try shaped.advanceSpans();
            var work: caret_visual.Work = .{ .remaining = self.limits.caret_work };
            var index = try caret_visual.Index.init(self.allocator, spans, &work);
            defer index.close(self.allocator);
            const at = try graphemeIndex(shaped, byte);
            if (at < try shaped.graphemeCount()) {
                var query = try index.query(spans, byte, try shaped.graphemeByte(at + 1), rowAt(try shaped.lines(), native.y + native.height * 0.5), native.x, &work);
                while (try query.next(spans, &work)) |rect| {
                    if (cells.items.len >= self.limits.rectangles -| (selected_count + composition_count)) return error.RectangleCapacityExceeded;
                    try cells.append(self.allocator, rect);
                }
            }
            if (@max(@as(usize, 1), cells.items.len) > (self.limits.rectangles -| (selected_count + composition_count)) / 4) return error.RectangleCapacityExceeded;
        }
        return .{ .selection = selection, .composition = composition, .caret = native, .source = selected, .affinity = affinity, .cells = try cells.toOwnedSlice(self.allocator), .cells_enabled = cells_enabled };
    }
    fn planScroll(self: *Adapter, bounds: Rect, metrics: t.Rect, caret: t.Rect) !ui.scroll.ScrollModel {
        var scroll = self.editor.scroll;
        _ = try scroll.setSizes(.{ .width = bounds.width, .height = bounds.height }, .{ .width = @max(1, metrics.x + metrics.width + 1), .height = @max(1, metrics.y + metrics.height) });
        if (self.editor.reveal_caret) _ = try scroll.ensureVisible(toRect(caret));
        return scroll;
    }
    fn current(self: *Adapter, bounds: Rect, scale: f32) !*Snapshot {
        try validBounds(bounds);
        if (self.snapshot) |*snapshot| {
            if (snapshot.revision == self.editor.display_revision and snapshot.buffer_revision == self.editor.buffer.revision and !self.editor.display_dirty and snapshot.width == bounds.width and snapshot.height == bounds.height and snapshot.scale == scale and std.meta.eql(snapshot.viewport, visibleViewport(bounds, self.editor.scroll)) and std.meta.eql(snapshot.geometry.source, self.editor.displaySelection()) and snapshot.geometry.affinity == self.affinity) return snapshot;
        }
        return error.LayoutRequired;
    }
    /// No shaping or allocation. The caller clips drawing to bounds.
    pub fn draw(self: *Adapter, bounds: Rect, scale: f32, surface: Surface) !void {
        try self.enter();
        defer self.busy = false;
        const snapshot = try self.current(bounds, scale);
        const origin: Point = .{ .x = bounds.x - self.editor.scroll.offset.x, .y = bounds.y - self.editor.scroll.offset.y };
        for (snapshot.geometry.selection) |rect| try surface.paint(surface.context, .{ .selection = translated(rect, origin) });
        try surface.paint(surface.context, .{ .text = .{ .prepared = snapshot.prepared, .origin = origin } });
        for (snapshot.geometry.composition) |rect| {
            var underline = translated(rect, origin);
            underline.y += @max(0, underline.height - 1);
            underline.height = 1;
            try surface.paint(surface.context, .{ .composition = underline });
        }
        if (self.editor.focused and self.editor.window_active) try surface.paint(surface.context, .{ .caret = translated(snapshot.geometry.caret, origin) });
    }
    /// Opt-in visual caret. The service caretRect remains the original native
    /// insertion bar. This does not prepare, shape, allocate or change focus.
    pub fn drawStyled(self: *Adapter, bounds: Rect, scale: f32, surface: Surface, style: caret_visual.Style) !void {
        try self.enter();
        defer self.busy = false;
        try style.validate();
        const paint = surface.paint_caret orelse return error.MissingCaretPainter;
        const snapshot = try self.current(bounds, scale);
        if (style.shape != .bar and !snapshot.geometry.cells_enabled) return error.CaretCellsRequired;
        const origin: Point = .{ .x = bounds.x - self.editor.scroll.offset.x, .y = bounds.y - self.editor.scroll.offset.y };
        const focused = self.editor.focused and self.editor.window_active and style.active;
        try paintStyled(snapshot.geometry, origin, style, false, surface.context, checkCaretPaint);
        try paintStyled(snapshot.geometry, origin, style, true, surface.context, checkCaretPaint);
        const collapsed = snapshot.geometry.source.anchor == snapshot.geometry.source.caret;
        const composing = self.editor.buffer.composition() != null;
        const background = style.enabled and focused and collapsed and !composing and style.shape == .block;
        for (snapshot.geometry.selection) |rect| try surface.paint(surface.context, .{ .selection = translated(rect, origin) });
        if (background) try paintStyled(snapshot.geometry, origin, style, false, surface.context, paint);
        try surface.paint(surface.context, .{ .text = .{ .prepared = snapshot.prepared, .origin = origin } });
        for (snapshot.geometry.composition) |rect| {
            var underline = translated(rect, origin);
            underline.y += @max(0, underline.height - 1);
            underline.height = 1;
            try surface.paint(surface.context, .{ .composition = underline });
        }
        if (!style.enabled) return;
        if (focused) {
            if (!background) {
                var effective = style;
                if (!collapsed or composing) effective.shape = .bar;
                try paintStyled(snapshot.geometry, origin, effective, false, surface.context, paint);
            }
        } else if (style.unfocused == .outline and collapsed and !composing) try paintStyled(snapshot.geometry, origin, style, true, surface.context, paint);
    }
    /// Current candidate location in window DIP, including scroll translation.
    pub fn caretRect(self: *Adapter, bounds: Rect, scale: f32) !Rect {
        try self.enter();
        defer self.busy = false;
        return translated((try self.current(bounds, scale)).geometry.caret, .{ .x = bounds.x - self.editor.scroll.offset.x, .y = bounds.y - self.editor.scroll.offset.y });
    }
    pub fn hitTest(self: *Adapter, bounds: Rect, point: Point) !t.Caret {
        try self.enter();
        defer self.busy = false;
        const scale = if (self.snapshot) |snapshot| snapshot.scale else return error.LayoutRequired;
        const snapshot = try self.current(bounds, scale);
        return (try snapshot.layout.hitTest(.{ .x = point.x - bounds.x + self.editor.scroll.offset.x, .y = point.y - bounds.y + self.editor.scroll.offset.y })).caret;
    }
    fn hitInner(self: *Adapter, bounds: Rect, point: Point) !t.Caret {
        const snapshot = try self.ensure(bounds);
        return (try snapshot.layout.hitTest(.{ .x = point.x - bounds.x + self.editor.scroll.offset.x, .y = point.y - bounds.y + self.editor.scroll.offset.y })).caret;
    }
    fn ensure(self: *Adapter, bounds: Rect) !*Snapshot {
        const old = if (self.snapshot) |*snapshot| snapshot else return error.LayoutRequired;
        _ = try self.prepareInner(bounds, .{ .font = try old.layout.options(), .scale = old.scale, .version = old.version, .caret_cells = old.geometry.cells_enabled });
        return &self.snapshot.?;
    }
    /// Text/IME and clipboard edits use the existing Editor. Call prepare after
    /// accepted edits, outside paint. Layout-dependent navigation may prepare at
    /// this explicit input boundary, including after composition cancellation.
    pub fn handleEvent(self: *Adapter, event: z.Event, bounds: Rect) !bool {
        try self.enter();
        defer self.busy = false;
        try validBounds(bounds);
        switch (event) {
            .pointer_down => |pointer| {
                const point = pointer.position;
                if (!bounds.contains(point)) {
                    self.editor.focused = false;
                    self.editor.dragging = false;
                    _ = self.editor.cancelComposition();
                    return false;
                }
                _ = self.editor.cancelComposition();
                const hit = try self.hitInner(bounds, .{ .x = point.x, .y = point.y });
                _ = try self.editor.buffer.setSelection(.{ .anchor = hit.byte_offset, .caret = hit.byte_offset });
                self.affinity = hit.affinity;
                self.editor.focused = true;
                self.editor.dragging = true;
                self.editor.preferred_x = null;
                self.editor.reveal_caret = true;
                return true;
            },
            .pointer_move, .pointer_up => {
                const point = if (event == .pointer_up) event.pointer_up.position else event.pointer_move;
                if (!self.editor.dragging) return false;
                if (event == .pointer_up) self.editor.dragging = false;
                const hit = try self.hitInner(bounds, .{ .x = point.x, .y = point.y });
                _ = try self.editor.buffer.setSelection(.{ .anchor = self.editor.buffer.selection().anchor, .caret = hit.byte_offset });
                self.affinity = hit.affinity;
                self.editor.reveal_caret = true;
                return true;
            },
            .key_input => |input| {
                if (!self.editor.focused or !self.editor.window_active or input.modifiers.alt or input.modifiers.super) return false;
                return self.key(input.key, input.modifiers.shift, input.modifiers.control, bounds);
            },
            .edit_key => |input| {
                if (!self.editor.focused or !self.editor.window_active) return false;
                return self.key(switch (input.key) {
                    .left => .left,
                    .right => .right,
                    .up => .up,
                    .down => .down,
                    .home => .home,
                    .end => .end,
                    .backspace => .backspace,
                    .delete => .delete,
                    .a => .a,
                    .c => .c,
                    .x => .x,
                    .v => .v,
                    .z => .z,
                    .y => .y,
                }, input.shift, input.control, bounds);
            },
            else => return self.editor.handleEvent(event, bounds, fallbackSurface(self.editor)),
        }
    }
    fn key(self: *Adapter, key_code: z.KeyCode, shift: bool, control: bool, bounds: Rect) !bool {
        if (control) switch (key_code) {
            .a, .c, .x, .v, .z, .y => {
                const code: z.EditKeyCode = switch (key_code) {
                    .a => .a,
                    .c => .c,
                    .x => .x,
                    .v => .v,
                    .z => .z,
                    .y => .y,
                    else => unreachable,
                };
                _ = try self.editor.key(.{ .key = code, .control = true, .shift = shift }, fallbackSurface(self.editor));
                self.affinity = .downstream;
                return true;
            },
            .home, .end => {},
            else => return false,
        };
        switch (key_code) {
            .left, .right, .up, .down, .home, .end, .page_up, .page_down, .backspace, .delete => {},
            else => return self.editor.handleEvent(.{ .key_input = .{ .key = key_code, .modifiers = .{ .shift = shift, .control = control } } }, bounds, fallbackSurface(self.editor)),
        }
        _ = self.editor.cancelComposition();
        const snapshot = try self.ensure(bounds);
        const selected = self.editor.buffer.selection();
        const caret: t.Caret = .{ .byte_offset = try snap(snapshot.layout, selected.caret, true), .affinity = self.affinity };
        const rect = try snapshot.layout.caret(caret);
        var target = caret;
        switch (key_code) {
            .backspace, .delete => {
                const range = selected.range();
                var first = try snap(snapshot.layout, range.start, false);
                var last = try snap(snapshot.layout, range.end, true);
                if (first == last) {
                    const index = try graphemeIndex(snapshot.layout, first);
                    if (key_code == .backspace) first = try snapshot.layout.graphemeByte(index -| 1) else last = try snapshot.layout.graphemeByte(@min(index + 1, try snapshot.layout.graphemeCount()));
                }
                if (try self.editor.buffer.replaceRange(.{ .start = first, .end = last }, "")) self.editor.refresh();
                self.affinity = .downstream;
                self.editor.preferred_x = null;
                return true;
            },
            .left, .right => {
                self.editor.preferred_x = null;
                if (!shift and selected.anchor != selected.caret) {
                    const first: t.Caret = .{ .byte_offset = try snap(snapshot.layout, selected.range().start, false) };
                    const last: t.Caret = .{ .byte_offset = try snap(snapshot.layout, selected.range().end, true), .affinity = .upstream };
                    const a = try snapshot.layout.caret(first);
                    const b = try snapshot.layout.caret(last);
                    target = if ((a.y < b.y or (a.y == b.y and a.x < b.x)) == (key_code == .left)) first else last;
                } else target = visualStep(snapshot, rowAt(try snapshot.layout.lines(), rect.y + rect.height * 0.5), rect, caret, key_code == .right);
            },
            .up, .down, .page_up, .page_down => {
                const lines = try snapshot.layout.lines();
                const row = rowAt(lines, rect.y + rect.height * 0.5);
                const x = self.editor.preferred_x orelse rect.x;
                self.editor.preferred_x = x;
                const forwards = key_code == .down or key_code == .page_down;
                const distance = if (key_code == .page_up or key_code == .page_down) @max(1, bounds.height) else rect.height;
                const y = rect.y + rect.height * 0.5 + (if (forwards) distance else -distance);
                const desired_row = rowAt(lines, y);
                const target_row = if (desired_row == row) (if (forwards) @min(row + 1, lines.len - 1) else row -| 1) else desired_row;
                target = (try snapshot.layout.hitTest(.{ .x = x, .y = lines[target_row].y + lines[target_row].height * 0.5 })).caret;
            },
            .home, .end => {
                self.editor.preferred_x = null;
                if (control) target = .{ .byte_offset = if (key_code == .home) 0 else self.editor.buffer.text().len } else {
                    const lines = try snapshot.layout.lines();
                    const row = snapshot.rows[rowAt(lines, rect.y + rect.height * 0.5)];
                    if (row.start != row.end) target = snapshot.stops[if (key_code == .home) row.start else row.end - 1].caret;
                }
            },
            else => unreachable,
        }
        _ = try self.editor.buffer.setSelection(.{ .anchor = if (shift) selected.anchor else target.byte_offset, .caret = target.byte_offset });
        self.affinity = target.affinity;
        self.editor.reveal_caret = true;
        return true;
    }
};

fn paintStyled(geometry: Geometry, origin: Point, style: caret_visual.Style, outline: bool, context: *anyopaque, paint: *const fn (*anyopaque, caret_visual.Paint) anyerror!void) !void {
    const fallback = caret_visual.terminal(geometry.caret, if (style.shape == .bar) style.thickness else style.terminal_width);
    const rects: []const caret_visual.Rect = if (style.shape == .bar or geometry.cells.len == 0) &.{fallback} else geometry.cells;
    for (rects) |rect| {
        var placed = rect;
        placed.x += origin.x;
        placed.y += origin.y;
        if (outline) {
            const marks = caret_visual.outlined(placed, style.thickness);
            for (marks.items[0..marks.len]) |mark| try paint(context, mark);
        } else try paint(context, caret_visual.filled(placed, style, style.shape == .block));
    }
}
fn checkCaretPaint(_: *anyopaque, paint: caret_visual.Paint) !void {
    try caret_visual.validateRect(paint.rect);
}

fn validBounds(bounds: Rect) !void {
    if (!ui.layout.validRect(bounds) or bounds.width <= 0 or bounds.height <= 0) return error.InvalidGeometry;
}
fn visibleViewport(bounds: Rect, scroll: ui.scroll.ScrollModel) t.drawing.Rect {
    const padding = 16;
    return .{ .x = scroll.offset.x - padding, .y = scroll.offset.y - padding, .width = bounds.width + 2 * padding, .height = bounds.height + 2 * padding };
}
fn sameFont(a: t.Options, b: t.Options) bool {
    return a.size == b.size and a.weight == b.weight and a.italic == b.italic and a.width == b.width and a.wrap == b.wrap and a.direction == b.direction and a.word_ranges == b.word_ranges and std.mem.eql(u8, a.family, b.family) and std.mem.eql(u8, a.locale, b.locale);
}
fn toRect(rect: t.Rect) Rect {
    return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
}
fn translated(rect: t.Rect, origin: Point) Rect {
    return .{ .x = rect.x + origin.x, .y = rect.y + origin.y, .width = rect.width, .height = rect.height };
}
fn rowAt(lines: []const t.Line, y: f32) usize {
    var low: usize = 0;
    var high = lines.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (lines[middle].y + lines[middle].height <= y) low = middle + 1 else high = middle;
    }
    return @min(low, lines.len - 1);
}
fn stopLess(_: void, a: Stop, b: Stop) bool {
    if (a.line != b.line) return a.line < b.line;
    if (a.rect.x != b.rect.x) return a.rect.x < b.rect.x;
    if (a.caret.byte_offset != b.caret.byte_offset) return a.caret.byte_offset < b.caret.byte_offset;
    return @intFromEnum(a.caret.affinity) < @intFromEnum(b.caret.affinity);
}
fn visualStep(snapshot: *const Snapshot, row_index: usize, rect: t.Rect, current_caret: t.Caret, forwards: bool) t.Caret {
    const row = snapshot.rows[row_index];
    const stops = snapshot.stops[row.start..row.end];
    var low: usize = 0;
    var high = stops.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const before = stops[mid].rect.x <= rect.x + 0.01;
        if (before) low = mid + 1 else high = mid;
    }
    if (forwards) {
        if (low < stops.len) return stops[low].caret;
        for (snapshot.rows[row_index + 1 ..]) |next| if (next.start != next.end) return snapshot.stops[next.start].caret;
        return current_caret;
    }
    var index = low;
    while (index > 0) {
        index -= 1;
        const candidate = stops[index];
        if (candidate.rect.x < rect.x - 0.01) return candidate.caret;
    }
    var previous_row = row_index;
    while (previous_row > 0) {
        previous_row -= 1;
        const previous = snapshot.rows[previous_row];
        if (previous.start != previous.end) return snapshot.stops[previous.end - 1].caret;
    }
    return current_caret;
}
fn graphemeIndex(shaped: *const t.Layout, byte: usize) !usize {
    var low: usize = 0;
    var high = try shaped.graphemeCount();
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (try shaped.graphemeByte(mid) < byte) low = mid + 1 else high = mid;
    }
    return low;
}
fn snap(shaped: *const t.Layout, byte: usize, forwards: bool) !usize {
    const index = try graphemeIndex(shaped, byte);
    const found = try shaped.graphemeByte(index);
    return if (found == byte or forwards) found else try shaped.graphemeByte(index -| 1);
}
fn fallbackSurface(editor: *Editor) ui.editor.Surface {
    return .{ .context = editor, .line_height = 1, .measure = noMeasure, .paint = noPaint };
}
fn noMeasure(_: *anyopaque, _: []const u8) !f32 {
    return error.VisualAdapterRequired;
}
fn noPaint(_: *anyopaque, _: ui.editor.PaintCommand) !void {
    return error.VisualAdapterRequired;
}
