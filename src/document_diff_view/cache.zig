const std = @import("std");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
pub const max_parts = 32;
pub const Part = struct { line: usize, range: d.Range, top: f32, height: f32 };
pub const Budget = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    reserved: usize = 0,
    peak: usize = 0,
    pub fn take(self: *Budget, bytes: usize) !void {
        if (bytes > self.limit -| self.reserved) return error.CapacityExceeded;
        self.reserved += bytes;
        self.peak = @max(self.peak, self.reserved);
    }
    pub fn release(self: *Budget, bytes: usize) void {
        self.reserved -= bytes;
    }
};
pub const Entry = struct {
    budget: *Budget,
    credit: usize,
    refs: usize = 1,
    side: u1,
    text_version: u64,
    generation: u64,
    layout: *t.Layout,
    parts: [max_parts]Part = undefined,
    count: usize,
    pub fn find(self: *const Entry, line: usize) ?usize {
        for (self.parts[0..self.count], 0..) |part, at| if (part.line == line) return at;
        return null;
    }
    pub fn retain(self: *Entry) *Entry {
        self.refs += 1;
        return self;
    }
    pub fn release(self: *Entry) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        const budget = self.budget;
        const credit = self.credit;
        self.layout.close() catch unreachable;
        budget.allocator.destroy(self);
        budget.release(credit);
    }
    /// Whole source paragraphs only. Each line is queried in this explicit
    /// bounded preparation phase, never during global index creation or paint.
    pub fn create(budget: *Budget, engine: *t.Engine, source: *const d.Snapshot, side: u1, generation: u64, lines: []const usize, font: t.Options, paragraph_bytes: usize) !*Entry {
        std.debug.assert(lines.len > 0 and lines.len <= max_parts);
        const credit = 4 * 1024 * 1024 + paragraph_bytes + @sizeOf(Entry);
        try budget.take(credit);
        errdefer budget.release(credit);
        const self = try budget.allocator.create(Entry);
        errdefer budget.allocator.destroy(self);
        var ranges: [max_parts]d.Range = undefined;
        const total = try source.lineCount();
        for (lines, 0..) |line, at| {
            var range = try source.line(line);
            if (line + 1 < total) range.end += 1;
            if (range.end - range.start > paragraph_bytes) return error.ParagraphCapacityExceeded;
            ranges[at] = range;
            if (at != 0 and ranges[at - 1].end != range.start) return error.InvalidBatch;
        }
        const start = ranges[0].start;
        const end = ranges[lines.len - 1].end;
        if (end - start > paragraph_bytes) return error.BatchCapacityExceeded;
        const bytes = try budget.allocator.alloc(u8, end - start);
        defer budget.allocator.free(bytes);
        _ = try source.read(.{ .start = start, .end = end }, bytes);
        const layout = try engine.layout(bytes, font);
        errdefer layout.close() catch unreachable;
        self.* = .{ .budget = budget, .credit = credit, .side = side, .text_version = try source.committedTextVersion(), .generation = generation, .layout = layout, .count = lines.len };
        for (lines, 0..) |line, at| {
            const first = try layout.caret(.{ .byte_offset = ranges[at].start - start });
            const last = try layout.caret(.{ .byte_offset = ranges[at].end - start });
            const terminated = line + 1 < total;
            const height = (if (terminated) last.y else last.y + last.height) - first.y;
            if (!std.math.isFinite(height) or height <= 0 or height > 1000000) return error.InvalidParagraphMetrics;
            self.parts[at] = .{ .line = line, .range = ranges[at], .top = first.y, .height = height };
        }
        return self;
    }
};
pub const Plane = struct {
    entry: *Entry,
    prepared: ?*t.Prepared = null,
    viewport: ?t.Rect = null,
    credit: usize = 0,
    pub fn include(self: *Plane, top: f32, height: f32, width: f32) void {
        if (height <= 0) return;
        if (self.viewport) |*view| {
            const bottom = @max(view.y + view.height, top + height);
            view.y = @min(view.y, top);
            view.height = bottom - view.y;
        } else self.viewport = .{ .x = 0, .y = top, .width = width, .height = height };
    }
    pub fn prepare(self: *Plane, scale: f32, limits: t.PrepareLimits) !void {
        const viewport = self.viewport orelse return;
        const budget = self.entry.budget;
        try budget.take(limits.bytes);
        errdefer budget.release(limits.bytes);
        self.prepared = try self.entry.layout.prepare(scale, .{ .limits = limits, .viewport = .{ .x = viewport.x, .y = viewport.y, .width = viewport.width, .height = viewport.height } });
        self.credit = limits.bytes;
    }
    pub fn ensureUnused(self: *const Plane) !void {
        if (self.prepared) |prepared| try prepared.ensureUnused();
    }
    pub fn close(self: *Plane) void {
        if (self.prepared) |prepared| prepared.close() catch unreachable;
        self.entry.budget.release(self.credit);
        self.entry.release();
    }
};
