const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const requests = @import("requests.zig");
const ix = @import("index.zig");
const cache = @import("cache.zig");
const max_rows = 96;
const max_batches = 24;
pub const Limits = struct {
    rows: usize = 262144,
    index_bytes: usize = 16 * 1024 * 1024,
    bytes: usize = 512 * 1024 * 1024,
    visible_rows: usize = 48,
    batches: usize = 12,
    batch_rows: usize = 16,
    batch_bytes: usize = 16384,
    paragraph_bytes: usize = 65536,
    revert_bytes: usize = 1024 * 1024,
    prepared: t.PrepareLimits = .{ .pixels = 1024 * 1024, .bytes = 8 * 1024 * 1024 },
};
pub const Parameters = struct { font: t.Options = .{ .size = 16, .wrap = .word_character, .width = 1 }, scale: f32 = 1, version: u64 = 0, estimated_height: f32 = 20 };
pub const Colors = struct { text: ui.Color = ui.Color.rgb(0x202020), deleted: u32 = 0xffe9e9, added: u32 = 0xe5f6e9, deleted_detail: u32 = 0xffa6a6, added_detail: u32 = 0x9fe0ac, blank: u32 = 0xeeeeee, selected: u32 = 0x93b9e7, header: u32 = 0xe1e6ef, background: u32 = 0xffffff };
pub const Direction = enum { a_to_b, b_to_a };
pub const Side = enum(u1) { a, b };
pub const RowInfo = struct { row: usize, a: ?usize, b: ?usize, hunk: ?usize, bounds: ui.Rect, a_content: ?ui.Rect, b_content: ?ui.Rect };
pub const Info = struct { serial: u64, selected_hunk: ?usize, rows: usize, total_rows: usize, estimated_extent: f64, anchor_row: usize, revert_button: ui.Rect };
pub const Stats = struct { reserved_bytes: usize, peak_reserved_bytes: usize, shaped_batches: u64, shaped_bytes: u64, indexed_rows: usize, header_layouts: u64, header_prepared: u64, header_reuses: u64 };
const Ref = struct { plane: usize, part: usize };
const RenderRow = struct { index: usize, y: f32, height: f32, ticks: u64, hunk: ?usize, sides: [2]?Ref };
const HeaderResource = struct {
    budget: *cache.Budget,
    refs: usize = 1,
    generation: u64,
    scale: f32,
    height: f32,
    layout: *t.Layout,
    prepared: *t.Prepared,
    credit: usize,
    fn retain(self: *HeaderResource) *HeaderResource {
        self.refs += 1;
        return self;
    }
    fn release(self: *HeaderResource) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        const budget = self.budget;
        const credit = self.credit;
        self.prepared.close() catch unreachable;
        self.layout.close() catch unreachable;
        budget.allocator.destroy(self);
        budget.release(credit);
    }
};
const Header = struct { resource: *HeaderResource, origin: ui.layout.Point };
const Snapshot = struct {
    serial: u64,
    generation: u64,
    a_revision: u64,
    b_revision: u64,
    bounds: ui.Rect,
    columns: [2]ui.Rect,
    button: ui.Rect,
    scale: f32,
    rows: [max_rows]RenderRow = undefined,
    row_count: usize = 0,
    planes: [max_batches]cache.Plane = undefined,
    plane_count: usize = 0,
    headers: [3]Header = undefined,
    header_count: usize = 0,
    fn ensureUnused(self: *const Snapshot) !void {
        for (self.planes[0..self.plane_count]) |*plane| try plane.ensureUnused();
        for (self.headers[0..self.header_count]) |header| try header.resource.prepared.ensureUnused();
    }
    fn close(self: *Snapshot) void {
        for (self.planes[0..self.plane_count]) |*plane| plane.close();
        for (self.headers[0..self.header_count]) |header| header.resource.release();
        self.plane_count = 0;
        self.header_count = 0;
    }
};
const Font = struct {
    options: t.Options = .{},
    family: [255]u8 = undefined,
    locale: [127]u8 = undefined,
    family_len: usize = 0,
    locale_len: usize = 0,
    fn get(self: *const Font) t.Options {
        var value = self.options;
        value.family = self.family[0..self.family_len];
        value.locale = self.locale[0..self.locale_len];
        return value;
    }
    fn set(self: *Font, value: t.Options) void {
        self.options = value;
        self.options.family = "";
        self.options.locale = "";
        self.family_len = value.family.len;
        self.locale_len = value.locale.len;
        @memcpy(self.family[0..value.family.len], value.family);
        @memcpy(self.locale[0..value.locale.len], value.locale);
    }
};

/// Side-by-side comparison and atomic hunk revert. The two existing Adapters
/// keep the only editable Documents/history. This first view deliberately has
/// no parallel text selection, native IME client or unified/editable mode.
pub const View = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    inbox: *requests.Inbox,
    adapters: [2]*editing.Adapter,
    engine: *t.Engine,
    window: z.Window,
    limits: Limits,
    budget: cache.Budget,
    busy: bool = false,
    required: bool = true,
    index: ?ix.Index = null,
    source_serial: u64 = 0,
    anchor: ix.Anchor = .{},
    selected: ?usize = null,
    snapshot: ?Snapshot = null,
    warm: [max_batches]?*cache.Entry = @splat(null),
    warm_count: usize = 0,
    font: Font = .{},
    configured: bool = false,
    generation: u64 = 0,
    version: u64 = 0,
    estimated_height: f32 = 20,
    shaped_batches: u64 = 0,
    shaped_bytes: u64 = 0,
    header_layouts: u64 = 0,
    header_prepared: u64 = 0,
    header_reuses: u64 = 0,
    pub fn create(allocator: std.mem.Allocator, inbox: *requests.Inbox, a: *editing.Adapter, b: *editing.Adapter, engine: *t.Engine, window: z.Window, limits: Limits) !*View {
        if (inbox.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (limits.rows == 0 or limits.rows > 2097152 or limits.index_bytes == 0 or limits.index_bytes > 1024 * 1024 * 1024 or limits.bytes < @sizeOf(View) or limits.bytes > 1024 * 1024 * 1024 or limits.visible_rows == 0 or limits.visible_rows > max_rows or limits.batches < 2 or limits.batches > max_batches or limits.batch_rows == 0 or limits.batch_rows > cache.max_parts or limits.batch_bytes == 0 or limits.batch_bytes > limits.paragraph_bytes or limits.paragraph_bytes > 65536 or limits.revert_bytes == 0 or limits.revert_bytes > 64 * 1024 * 1024 or limits.prepared.pixels == 0 or limits.prepared.pixels > 16 * 1024 * 1024 or limits.prepared.bytes == 0 or limits.prepared.bytes > 64 * 1024 * 1024) return error.InvalidLimits;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (try a.sourceDocument() != inbox.pair.a or try b.sourceDocument() != inbox.pair.b) return error.ForeignDocument;
        _ = try engine.lastNativeError();
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
        const self = try allocator.create(View);
        errdefer allocator.destroy(self);
        if (window.isClosed()) return error.Closed;
        self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .inbox = inbox, .adapters = .{ a, b }, .engine = engine, .window = window, .limits = limits, .budget = .{ .allocator = allocator, .limit = limits.bytes, .reserved = @sizeOf(View), .peak = @sizeOf(View) } };
        return self;
    }
    fn check(self: *const View) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.busy) return error.Busy;
    }
    pub fn close(self: *View) !void {
        try self.check();
        const scope = self.window.app.beginTeardownCallback();
        defer scope.end();
        if (self.snapshot) |*snapshot| try snapshot.ensureUnused();
        for (self.adapters) |adapter| {
            _ = try adapter.sourceDocument();
            try adapter.ensureUnused();
        }
        const borrow = try self.inbox.borrowForTeardown();
        defer borrow.end();
        self.busy = true;
        if (self.snapshot) |*snapshot| snapshot.close();
        for (self.warm[0..self.warm_count]) |entry| entry.?.release();
        if (self.index) |*index| {
            const bytes = index.bytes;
            index.close();
            self.budget.release(bytes);
        }
        for (self.adapters) |adapter| adapter.releaseClient() catch unreachable;
        borrow.releaseClient() catch unreachable;
        std.debug.assert(self.budget.reserved == @sizeOf(View));
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    pub fn prepare(self: *View, bounds: ui.Rect, parameters: Parameters) !void {
        try self.check();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        return self.prepareInner(bounds, parameters);
    }
    fn prepareInner(self: *View, bounds: ui.Rect, parameters: Parameters) !void {
        if (!ui.layout.validRect(bounds) or bounds.width < 80 or bounds.height < 40 or bounds.width > 1000000 or bounds.height > 1000000 or !std.math.isFinite(parameters.scale) or parameters.scale <= 0 or parameters.scale > 16 or parameters.font.family.len > 255 or parameters.font.locale.len > 127) return error.InvalidGeometry;
        _ = try ix.ticks(parameters.estimated_height);
        if (self.snapshot) |*snapshot| try snapshot.ensureUnused();
        errdefer self.required = true;
        const borrow = try self.inbox.borrow();
        defer borrow.end();
        const display = try borrow.display() orelse return error.ComparisonRequired;
        if (try self.inbox.pair.a.composition() != null or try self.inbox.pair.b.composition() != null) return error.CompositionActive;
        const revision_a = try self.inbox.pair.a.version();
        const revision_b = try self.inbox.pair.b.version();
        const header_height = @min(bounds.height - 1, @max(24, parameters.font.size * 1.8));
        const width = (bounds.width - 8) / 2;
        const columns: [2]ui.Rect = .{ .{ .x = bounds.x, .y = bounds.y + header_height, .width = width, .height = bounds.height - header_height }, .{ .x = bounds.x + width + 8, .y = bounds.y + header_height, .width = width, .height = bounds.height - header_height } };
        var font = parameters.font;
        font.width = width;
        if (font.wrap == .none) font.width = 0;
        const same = self.configured and parameters.version == self.version and fontEqual(font, self.font.get());
        const generation = if (same) self.generation else std.math.add(u64, self.generation, 1) catch return error.IdExhausted;
        const same_estimate = self.configured and parameters.estimated_height == self.estimated_height;
        if (!self.required and same and same_estimate) if (self.snapshot) |*snapshot| if (snapshot.serial == display.serial and std.meta.eql(snapshot.bounds, bounds) and snapshot.scale == parameters.scale) {
            snapshot.a_revision = revision_a;
            snapshot.b_revision = revision_b;
            return;
        };
        var candidate_index: ?ix.Index = null;
        defer if (candidate_index) |*index| {
            const bytes = index.bytes;
            index.close();
            self.budget.release(bytes);
        };
        const rebuild = self.index == null or self.source_serial != display.serial or !same or !same_estimate;
        if (rebuild) {
            const available = @min(self.limits.index_bytes, self.limits.bytes -| self.budget.reserved);
            candidate_index = try ix.Index.create(self.allocator, &display.result, self.limits.rows, available, parameters.estimated_height);
            try self.budget.take(candidate_index.?.bytes);
        }
        const index = if (candidate_index) |*value| value else &self.index.?;
        var anchor = self.anchor;
        if (index.heights.len == 0) anchor = .{} else {
            anchor.row = @min(anchor.row, index.heights.len - 1);
            anchor.inset = @min(anchor.inset, index.heights[anchor.row] - 1);
        }
        var candidate: Snapshot = .{ .serial = display.serial, .generation = generation, .a_revision = revision_a, .b_revision = revision_b, .bounds = bounds, .columns = columns, .button = .{ .x = bounds.x + bounds.width - 136, .y = bounds.y, .width = 136, .height = header_height }, .scale = parameters.scale };
        defer candidate.close();
        var row = anchor.row;
        var y = -@as(f32, @floatCast(ix.dip(anchor.inset)));
        while (row < index.heights.len and y < columns[0].height) {
            if (candidate.row_count == self.limits.visible_rows) return error.VisibleRowCapacityExceeded;
            const mapped = index.row(row);
            var refs: [2]?Ref = @splat(null);
            var height: f32 = 0;
            for ([_]Side{ .a, .b }) |side| {
                const line = if (side == .a) mapped.a else mapped.b;
                if (line) |source_line| {
                    const ref = try self.resolve(&candidate, index, display, side, row, source_line, font, generation);
                    refs[@backingInt(side)] = ref;
                    height = @max(height, candidate.planes[ref.plane].entry.parts[ref.part].height);
                }
            }
            const ticks = try ix.ticks(height);
            if (candidate.row_count == 0 and anchor.inset >= ticks) {
                anchor.inset = ticks - 1;
                y = -@as(f32, @floatCast(ix.dip(anchor.inset)));
            }
            const actual: @TypeOf(height) = @floatCast(ix.dip(ticks));
            candidate.rows[candidate.row_count] = .{ .index = row, .y = y, .height = actual, .ticks = ticks, .hunk = mapped.hunk, .sides = refs };
            for (refs) |reference| if (reference) |ref| {
                const part = candidate.planes[ref.plane].entry.parts[ref.part];
                const top = @max(0, -y);
                const bottom = @min(part.height, columns[0].height - y);
                if (bottom > top) candidate.planes[ref.plane].include(part.top + top, bottom - top, width);
            };
            candidate.row_count += 1;
            y += actual;
            row += 1;
        }
        for (candidate.planes[0..candidate.plane_count]) |*plane| try plane.prepare(parameters.scale, self.limits.prepared);
        const title_options = blk: {
            var value = parameters.font;
            value.width = 0;
            value.wrap = .none;
            break :blk value;
        };
        try self.header(&candidate, "Original", .{ .x = bounds.x + 4, .y = bounds.y + 2 }, title_options, header_height, parameters.scale);
        try self.header(&candidate, "Modified", .{ .x = columns[1].x + 4, .y = bounds.y + 2 }, title_options, header_height, parameters.scale);
        try self.header(&candidate, "Revert selected", .{ .x = candidate.button.x + 4, .y = bounds.y + 2 }, title_options, header_height, parameters.scale);
        if (self.window.isClosed()) return error.Closed;
        if (!try self.inbox.fresh(display.result.a, display.result.b) or revision_a != try self.inbox.pair.a.version() or revision_b != try self.inbox.pair.b.version()) return error.StaleRevision;
        var previous_index: ?ix.Index = null;
        if (rebuild) std.mem.swap(?ix.Index, &previous_index, &self.index);
        if (rebuild) std.mem.swap(?ix.Index, &candidate_index, &self.index);
        for (candidate.rows[0..candidate.row_count]) |item| self.index.?.set(item.index, item.ticks);
        self.anchor = anchor;
        self.source_serial = display.serial;
        if (self.selected) |selected| {
            if (selected >= display.result.hunks.len) self.selected = if (display.result.hunks.len == 0) null else display.result.hunks.len - 1;
        } else if (display.result.hunks.len != 0) self.selected = 0;
        var previous: ?Snapshot = null;
        std.mem.swap(?Snapshot, &previous, &self.snapshot);
        self.snapshot = candidate;
        candidate.plane_count = 0;
        candidate.header_count = 0;
        var warm: [max_batches]?*cache.Entry = @splat(null);
        var count: usize = 0;
        for (self.snapshot.?.planes[0..self.snapshot.?.plane_count]) |plane| {
            warm[count] = plane.entry.retain();
            count += 1;
        }
        for (self.warm[0..self.warm_count]) |value| {
            if (count == self.limits.batches) break;
            const entry = value.?;
            if (entry.generation != generation) continue;
            const source = if (entry.side == 0) display.result.a else display.result.b;
            if (entry.text_version != source.text_version) continue;
            var present = false;
            for (warm[0..count]) |item| if (item.? == entry) {
                present = true;
                break;
            };
            if (!present) {
                warm[count] = entry.retain();
                count += 1;
            }
        }
        const old_warm = self.warm;
        const old_count = self.warm_count;
        self.warm = warm;
        self.warm_count = count;
        self.font.set(font);
        self.generation = generation;
        self.version = parameters.version;
        self.estimated_height = parameters.estimated_height;
        self.configured = true;
        self.required = false;
        if (previous) |value| {
            var old = value;
            old.close();
        }
        for (old_warm[0..old_count]) |entry| entry.?.release();
        if (previous_index) |value| {
            var old = value;
            const bytes = old.bytes;
            old.close();
            self.budget.release(bytes);
        }
        if (self.window.isClosed()) return error.Closed;
        if (!try self.inbox.fresh(display.result.a, display.result.b) or revision_a != try self.inbox.pair.a.version() or revision_b != try self.inbox.pair.b.version()) {
            self.required = true;
            return error.StaleRevision;
        }
    }
    fn resolve(self: *View, candidate: *Snapshot, index: *const ix.Index, display: *const requests.Display, side: Side, row: usize, line: usize, font: t.Options, generation: u64) !Ref {
        const tag = @backingInt(side);
        const source = if (side == .a) display.a else display.b;
        const text_version = try source.committedTextVersion();
        for (candidate.planes[0..candidate.plane_count], 0..) |plane, at| if (plane.entry.side == tag and plane.entry.generation == generation and plane.entry.text_version == text_version) if (plane.entry.find(line)) |part| return .{ .plane = at, .part = part };
        if (candidate.plane_count == self.limits.batches) return error.BatchCapacityExceeded;
        for (self.warm[0..self.warm_count]) |value| {
            const entry = value.?;
            if (entry.side != tag or entry.generation != generation or entry.text_version != text_version) continue;
            if (entry.find(line)) |part| {
                const at = candidate.plane_count;
                candidate.planes[at] = .{ .entry = entry.retain() };
                candidate.plane_count += 1;
                return .{ .plane = at, .part = part };
            }
        }
        var lines: [cache.max_parts]usize = undefined;
        var count: usize = 0;
        var bytes: usize = 0;
        const total = try source.lineCount();
        const end = @min(index.heights.len, row + @min(self.limits.batch_rows, self.limits.visible_rows - candidate.row_count));
        for (row..end) |at| {
            const mapped = index.row(at);
            const next = if (side == .a) mapped.a else mapped.b;
            if (next) |value| {
                const range = try source.line(value);
                const length = range.end - range.start + @intFromBool(value + 1 < total);
                if (count != 0 and length > self.limits.batch_bytes -| bytes) break;
                if (length > self.limits.paragraph_bytes) return error.ParagraphCapacityExceeded;
                lines[count] = value;
                count += 1;
                bytes += length;
            }
        }
        std.debug.assert(count != 0 and lines[0] == line);
        const entry = try cache.Entry.create(&self.budget, self.engine, source, tag, generation, lines[0..count], font, self.limits.paragraph_bytes);
        self.shaped_batches +|= 1;
        self.shaped_bytes +|= bytes;
        const at = candidate.plane_count;
        candidate.planes[at] = .{ .entry = entry };
        candidate.plane_count += 1;
        return .{ .plane = at, .part = 0 };
    }
    fn header(self: *View, candidate: *Snapshot, text: []const u8, origin: ui.layout.Point, font: t.Options, height: f32, scale: f32) !void {
        // Title identity is its fixed slot. Position does not enter the native
        // cache key: the same prepared coverage can be replayed at a new origin.
        const slot = candidate.header_count;
        if (self.snapshot) |*snapshot| if (slot < snapshot.header_count) {
            const resource = snapshot.headers[slot].resource;
            if (resource.generation == candidate.generation and resource.scale == scale and resource.height == height) {
                candidate.headers[slot] = .{ .resource = resource.retain(), .origin = origin };
                candidate.header_count += 1;
                self.header_reuses +|= 1;
                return;
            }
        };
        const credit = 4 * 1024 * 1024 + self.limits.prepared.bytes + @sizeOf(HeaderResource);
        try self.budget.take(credit);
        errdefer self.budget.release(credit);
        const resource = try self.allocator.create(HeaderResource);
        errdefer self.allocator.destroy(resource);
        self.header_layouts +|= 1;
        const layout = try self.engine.layout(text, font);
        errdefer layout.close() catch unreachable;
        self.header_prepared +|= 1;
        const prepared = try layout.prepare(scale, .{ .limits = self.limits.prepared, .viewport = .{ .x = 0, .y = 0, .width = 140, .height = height } });
        resource.* = .{ .budget = &self.budget, .generation = candidate.generation, .scale = scale, .height = height, .layout = layout, .prepared = prepared, .credit = credit };
        candidate.headers[slot] = .{ .resource = resource, .origin = origin };
        candidate.header_count += 1;
    }
    fn current(self: *View, bounds: ui.Rect, scale: f32) !*const Snapshot {
        if (self.inbox.stopping) return error.Closed;
        if (self.required) return error.LayoutRequired;
        const snapshot = if (self.snapshot) |*value| value else return error.LayoutRequired;
        if (!std.meta.eql(snapshot.bounds, bounds) or snapshot.scale != scale) return error.LayoutRequired;
        const borrow = try self.inbox.borrow();
        defer borrow.end();
        const display = try borrow.display() orelse return error.ComparisonRequired;
        if (snapshot.serial != display.serial or snapshot.a_revision != try self.inbox.pair.a.version() or snapshot.b_revision != try self.inbox.pair.b.version()) return error.LayoutRequired;
        if (try self.inbox.pair.a.composition() != null or try self.inbox.pair.b.composition() != null) return error.CompositionActive;
        return snapshot;
    }
    pub fn draw(self: *View, frame: *ui.Frame, bounds: ui.Rect, colors: Colors) anyerror!void {
        try self.check();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        return self.drawBody(frame, bounds, colors) catch |err| {
            frame.failure = frame.failure orelse err;
            return err;
        };
    }
    fn drawBody(self: *View, frame: *ui.Frame, bounds: ui.Rect, colors: Colors) anyerror!void {
        const snapshot = try self.current(bounds, frame.size.scale);
        try frame.pushClip(bounds);
        defer frame.popClip() catch |err| {
            frame.failure = frame.failure orelse err;
        };
        frame.rect(bounds, colors.background);
        frame.rect(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = snapshot.columns[0].y - bounds.y }, colors.header);
        for (snapshot.rows[0..snapshot.row_count]) |row| {
            for ([_]Side{ .a, .b }) |side| {
                const column = snapshot.columns[@backingInt(side)];
                const rectangle = ui.layout.intersect(.{ .x = column.x, .y = column.y + row.y, .width = column.width, .height = row.height }, column);
                if (rectangle.height == 0) continue;
                const reference = row.sides[@backingInt(side)];
                if (row.hunk != null) frame.rect(rectangle, if (reference == null) colors.blank else if (side == .a) colors.deleted else colors.added);
                if (row.hunk != null and row.hunk == self.selected) frame.rect(.{ .x = column.x, .y = rectangle.y, .width = 3, .height = rectangle.height }, colors.selected);
                if (reference) |ref| {
                    const plane = snapshot.planes[ref.plane];
                    const part = plane.entry.parts[ref.part];
                    if (plane.prepared) |prepared| {
                        const clip = ui.layout.intersect(rectangle, .{ .x = column.x, .y = column.y + row.y, .width = column.width, .height = part.height });
                        if (clip.height > 0) {
                            try frame.pushClip(clip);
                            defer frame.popClip() catch |err| {
                                frame.failure = frame.failure orelse err;
                            };
                            try frame.preparedText(.{ .x = column.x, .y = column.y + row.y - part.top }, try prepared.view(), colors.text);
                        }
                    }
                }
            }
        }
        for (snapshot.headers[0..snapshot.header_count]) |item| try frame.preparedText(item.origin, try item.resource.prepared.view(), colors.text);
        if (frame.failure) |err| return @as(anyerror!void, err);
    }
    pub fn info(self: *View) !Info {
        try self.check();
        const previous = self.snapshot orelse return error.LayoutRequired;
        const snapshot = try self.current(previous.bounds, previous.scale);
        const index = &self.index.?;
        return .{ .serial = snapshot.serial, .selected_hunk = self.selected, .rows = snapshot.row_count, .total_rows = index.heights.len, .estimated_extent = ix.dip(index.prefix(index.heights.len)), .anchor_row = self.anchor.row, .revert_button = snapshot.button };
    }
    /// Includes conservative native reservations and failed preparation work.
    /// It excludes the two Documents, Inbox result/Snapshots and host Adapters.
    pub fn stats(self: *const View) !Stats {
        try self.check();
        return .{ .reserved_bytes = self.budget.reserved, .peak_reserved_bytes = self.budget.peak, .shaped_batches = self.shaped_batches, .shaped_bytes = self.shaped_bytes, .indexed_rows = if (self.index) |*value| value.heights.len else 0, .header_layouts = self.header_layouts, .header_prepared = self.header_prepared, .header_reuses = self.header_reuses };
    }
    pub fn rowInfo(self: *View, destination: []RowInfo) ![]const RowInfo {
        try self.check();
        const previous = self.snapshot orelse return error.LayoutRequired;
        const snapshot = try self.current(previous.bounds, previous.scale);
        if (destination.len < snapshot.row_count) return error.CapacityExceeded;
        for (snapshot.rows[0..snapshot.row_count], destination[0..snapshot.row_count]) |row, *output| {
            const mapped = self.index.?.row(row.index);
            var content: [2]?ui.Rect = @splat(null);
            for (row.sides, 0..) |reference, side| if (reference) |ref| {
                const part = snapshot.planes[ref.plane].entry.parts[ref.part];
                content[side] = .{ .x = snapshot.columns[side].x, .y = snapshot.columns[side].y + row.y, .width = snapshot.columns[side].width, .height = part.height };
            };
            output.* = .{ .row = row.index, .a = mapped.a, .b = mapped.b, .hunk = row.hunk, .bounds = .{ .x = snapshot.bounds.x, .y = snapshot.columns[0].y + row.y, .width = snapshot.bounds.width, .height = row.height }, .a_content = content[0], .b_content = content[1] };
        }
        return destination[0..snapshot.row_count];
    }
    pub fn scrollBy(self: *View, delta: f32) !bool {
        try self.check();
        return self.scrollInner(delta);
    }
    fn scrollInner(self: *View, delta: f32) !bool {
        if (!std.math.isFinite(delta) or @abs(delta) > 1000000) return error.InvalidScroll;
        const index = if (self.index) |*value| value else return error.ComparisonRequired;
        const viewport = if (self.snapshot) |value| try ix.ticks(value.columns[0].height) else 1;
        const old = index.position(self.anchor);
        const change: i64 = @intFromFloat(@round(@as(f64, delta) * ix.units));
        const next: u64 = @intCast(@max(0, @as(i128, old) + change));
        const anchor = index.clamp(next, viewport);
        if (std.meta.eql(anchor, self.anchor)) return false;
        self.anchor = anchor;
        self.required = true;
        return true;
    }
    pub fn navigate(self: *View, forward: bool) !bool {
        try self.check();
        return self.navigateInner(forward);
    }
    fn navigateInner(self: *View, forward: bool) !bool {
        const borrow = try self.inbox.borrow();
        defer borrow.end();
        const display = try borrow.display() orelse return error.ComparisonRequired;
        if (display.result.hunks.len == 0) return false;
        if (self.index == null or self.source_serial != display.serial) return error.LayoutRequired;
        const next = if (self.selected) |at| if (forward) @min(at + 1, display.result.hunks.len - 1) else at -| 1 else if (forward) 0 else display.result.hunks.len - 1;
        const row = self.index.?.hunkRow(next) orelse return error.InvalidResult;
        self.selected = next;
        self.anchor = .{ .row = row };
        self.required = true;
        return true;
    }
    pub fn revert(self: *View, hunk: usize, direction: Direction) !editing.EditResult {
        try self.check();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        return self.revertInner(hunk, direction);
    }
    fn revertInner(self: *View, hunk: usize, direction: Direction) !editing.EditResult {
        const borrow = try self.inbox.borrow();
        defer borrow.end();
        const display = try borrow.display() orelse return error.ComparisonRequired;
        if (hunk >= display.result.hunks.len) return error.InvalidHunk;
        if (try self.inbox.pair.a.composition() != null or try self.inbox.pair.b.composition() != null) return error.CompositionActive;
        const selected = display.result.hunks[hunk];
        const source = if (direction == .a_to_b) display.a else display.b;
        const range = if (direction == .a_to_b) selected.a.bytes else selected.b.bytes;
        const target = if (direction == .a_to_b) selected.b.bytes else selected.a.bytes;
        const side: usize = if (direction == .a_to_b) 1 else 0;
        if (range.end - range.start > self.limits.revert_bytes) return error.RevertCapacityExceeded;
        const revision = try (if (side == 0) self.inbox.pair.a else self.inbox.pair.b).version();
        try self.budget.take(range.end - range.start);
        defer self.budget.release(range.end - range.start);
        const bytes = try self.allocator.alloc(u8, range.end - range.start);
        defer self.allocator.free(bytes);
        _ = try source.read(range, bytes);
        if (self.window.isClosed()) return error.Closed;
        if (!try self.inbox.fresh(display.result.a, display.result.b)) return error.StaleRevision;
        const result = try self.adapters[side].replaceMany(revision, &.{.{ .range = target, .text = bytes }});
        self.required = true;
        self.window.invalidate();
        return result;
    }
    pub fn handleEvent(self: *View, event: z.Event, bounds: ui.Rect, parameters: Parameters) !bool {
        try self.check();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        switch (event) {
            .wheel => |wheel| {
                if (!bounds.contains(wheel.position)) return false;
                if (try self.scrollInner(wheel.delta.y)) {
                    try self.prepareInner(bounds, parameters);
                    self.window.invalidate();
                }
                return true;
            },
            .key_input => |input| {
                if (try self.inbox.pair.a.composition() != null or try self.inbox.pair.b.composition() != null) return false;
                if (input.modifiers.alt or input.modifiers.super) return false;
                if (input.key == .f7) {
                    _ = try self.navigateInner(!input.modifiers.shift);
                    try self.prepareInner(bounds, parameters);
                    self.window.invalidate();
                    return true;
                }
                if (input.key == .enter and input.modifiers.control) {
                    if (self.selected) |selected| _ = try self.revertInner(selected, .a_to_b);
                    return true;
                }
                if (input.modifiers.control or input.modifiers.shift) return false;
                const amount: f32 = switch (input.key) {
                    .up => -parameters.estimated_height,
                    .down => parameters.estimated_height,
                    .page_up => -bounds.height * 0.8,
                    .page_down => bounds.height * 0.8,
                    else => return false,
                };
                _ = try self.scrollInner(amount);
                try self.prepareInner(bounds, parameters);
                self.window.invalidate();
                return true;
            },
            .pointer_down => |pointer| {
                const point = pointer.position;
                const previous = self.snapshot orelse return false;
                const snapshot = try self.current(bounds, previous.scale);
                if (snapshot.button.contains(point)) {
                    if (self.selected) |selected| _ = try self.revertInner(selected, .a_to_b);
                    return true;
                }
                for (snapshot.rows[0..snapshot.row_count]) |row| if (row.hunk != null and point.y >= snapshot.columns[0].y + row.y and point.y < snapshot.columns[0].y + row.y + row.height and bounds.contains(point)) {
                    self.selected = row.hunk;
                    self.window.invalidate();
                    return true;
                };
                return false;
            },
            .resize => {
                try self.prepareInner(bounds, parameters);
                return false;
            },
            else => return false,
        }
    }
};
fn fontEqual(a: t.Options, b: t.Options) bool {
    return a.size == b.size and a.weight == b.weight and a.italic == b.italic and a.width == b.width and a.wrap == b.wrap and a.direction == b.direction and std.mem.eql(u8, a.family, b.family) and std.mem.eql(u8, a.locale, b.locale);
}
