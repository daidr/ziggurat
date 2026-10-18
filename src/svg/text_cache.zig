const std = @import("std");
const v = @import("ziggurat_vector");
const text = @import("text.zig");
const pre = @import("prepare.zig");
const shapes = @import("shape.zig");
const styles = @import("style.zig");
const positioning = @import("text_position.zig");
const adjustment = @import("text_adjust.zig");
const painting = @import("text_paint.zig");
const Entry = struct { index: usize, font: text.Font, anchor: text.Anchor, preserve_space: bool, span_style: ?*styles.Style, viewport: shapes.Viewport, path: *v.Path, glyphs: usize, cells: ?[]v.Bounds, quads: ?[]adjustment.Quad = null, characters: usize, positions: usize, chunks: usize, painted: ?*painting.Product = null, uniform_fill: ?*painting.Fill = null };
pub const Fill = union(enum) { single: painting.Fill, parts: []const painting.Part };
pub const Cache = struct {
    work: *pre.Work,
    entries: []Entry = &.{},
    len: usize = 0,
    source_bytes: usize = 0,
    glyphs: usize = 0,
    commands: usize = 0,
    extra_commands: usize = 0,
    mapping_requests: usize = 0,
    paint_runs: usize = 0,
    paint_commands: usize = 0,
    characters: usize = 0,
    position_values: usize = 0,
    chunks: usize = 0,
    used: u64 = 0,
    requests: usize = 0,
    denied: bool = false,
    pub fn create(work: *pre.Work) !*Cache {
        if (!work.allocator_budgeted) try work.reserve(@sizeOf(Cache));
        errdefer if (!work.allocator_budgeted) {
            work.live -= @sizeOf(Cache);
        };
        const self = try work.allocator.create(Cache);
        errdefer work.allocator.destroy(self);
        self.* = .{ .work = work };
        self.entries = self.allocator().alloc(Entry, work.options.limits.text.instances) catch |err| return if (err == error.OutOfMemory and self.denied) error.CapacityExceeded else err;
        return self;
    }
    pub fn close(self: *Cache) void {
        for (self.entries[0..self.len]) |entry| {
            if (entry.span_style) |style| self.allocator().destroy(style);
            if (entry.uniform_fill) |value| self.allocator().destroy(value);
            if (entry.painted) |product| {
                product.close();
            } else {
                if (entry.cells) |cells| self.allocator().free(cells);
                if (entry.quads) |quads| self.allocator().free(quads);
                entry.path.close() catch unreachable;
            }
        }
        self.allocator().free(self.entries);
        const work = self.work;
        work.allocator.destroy(self);
        if (!work.allocator_budgeted) work.live -= @sizeOf(Cache);
    }
    pub fn contains(self: *const Cache, path: *v.Path) bool {
        for (self.entries[0..self.len]) |entry| if (entry.path == path) return true;
        return false;
    }
    pub fn hasCells(self: *const Cache, path: *v.Path) bool {
        for (self.entries[0..self.len]) |entry| if (entry.path == path) return entry.cells != null or entry.quads != null;
        return false;
    }
    pub fn fill(self: *const Cache, path: *v.Path, fallback: painting.Fill) Fill {
        for (self.entries[0..self.len]) |entry| if (entry.path == path) {
            if (entry.painted) |product| return .{ .parts = product.parts };
            if (entry.uniform_fill) |value| return .{ .single = value.* };
            return .{ .single = fallback };
        };
        return .{ .single = fallback };
    }
    /// Transform each full glyph cell before union; transforming an aggregate
    /// text rectangle would overestimate rotated/skewed multi-run text.
    pub fn bounds(self: *Cache, path: *v.Path, transform: v.Transform) !?v.Bounds {
        try transform.validate();
        for (self.entries[0..self.len]) |entry| if (entry.path == path) {
            const count = if (entry.quads) |quads| quads.len else if (entry.cells) |cells| cells.len else return error.UnsupportedTextBoundingBox;
            try self.charge(@as(u64, count) * 4);
            var result: ?v.Bounds = null;
            for (0..count) |i| {
                if (i % 256 == 0) try self.work.check();
                const corners = if (entry.quads) |quads| quads[i] else blk: {
                    const cell = entry.cells.?[i];
                    break :blk [_]v.Point{ .{ .x = cell.x, .y = cell.y }, .{ .x = cell.x + cell.width, .y = cell.y }, .{ .x = cell.x, .y = cell.y + cell.height }, .{ .x = cell.x + cell.width, .y = cell.y + cell.height } };
                };
                for (corners) |corner| {
                    const mapped = transform.apply(corner);
                    try v.validPoint(mapped);
                    if (result) |previous| {
                        const right = @max(previous.x + previous.width, mapped.x);
                        const bottom = @max(previous.y + previous.height, mapped.y);
                        const x = @min(previous.x, mapped.x);
                        const y = @min(previous.y, mapped.y);
                        result = .{ .x = x, .y = y, .width = right - x, .height = bottom - y };
                    } else result = .{ .x = mapped.x, .y = mapped.y, .width = 0, .height = 0 };
                }
            }
            return result;
        };
        return error.InvalidTextPath;
    }
    pub fn charge(self: *Cache, amount: u64) !void {
        if (amount > self.work.options.limits.text.work -| self.used) return error.TextWorkExceeded;
        self.used += amount;
    }
    fn use(self: *Cache, path: *v.Path, glyphs: usize, characters: usize, positions: usize, chunks: usize) !*v.Path {
        const limits = self.work.options.limits.text;
        if (glyphs > limits.glyphs -| self.glyphs or path.commands.len > limits.commands -| self.commands -| self.extra_commands) return error.TextCapacityExceeded;
        if (characters > limits.characters -| self.characters) return error.TextCharactersFull;
        if (positions > limits.position_values -| self.position_values) return error.TextPositionsFull;
        if (chunks > limits.chunks -| self.chunks) return error.TextChunksFull;
        try self.charge(glyphs + path.commands.len);
        self.glyphs += glyphs;
        self.commands += path.commands.len;
        self.characters += characters;
        self.position_values += positions;
        self.chunks += chunks;
        return path;
    }
    fn usePaint(self: *Cache, product: *painting.Product) !void {
        if (product.commands > self.work.options.limits.text.commands -| self.commands -| self.extra_commands) return error.TextCapacityExceeded;
        if (product.parts.len > self.work.options.limits.text.paint_runs -| self.paint_runs) return error.TextPaintRunsFull;
        try self.charge(product.commands + product.parts.len);
        self.extra_commands += product.commands;
        self.paint_commands += product.commands;
        self.paint_runs += product.parts.len;
    }
    pub fn geometry(self: *Cache, index: usize, frame: pre.Frame) !*v.Path {
        return self.geometryInner(index, frame) catch |err| return if (err == error.OutOfMemory and self.denied) error.CapacityExceeded else err;
    }
    /// A hidden text root can contain a visible descendant. Reject unsupported
    /// span differences before culling the root; do not invoke the font provider.
    pub fn validateHidden(self: *Cache, index: usize, frame: pre.Frame) !void {
        var plan = positioning.Plan.build(self, self.allocator(), index, frame) catch |err| return if (err == error.OutOfMemory and self.denied) error.CapacityExceeded else err;
        defer plan.deinit();
        try self.work.check();
    }
    fn geometryInner(self: *Cache, index: usize, frame: pre.Frame) !*v.Path {
        const work = self.work;
        const style = frame.style;
        const limits = work.options.limits.text;
        for (self.entries[0..self.len]) |entry| {
            try self.charge(1 + entry.font.family.len + entry.font.locale.len);
            if (entry.index != index or entry.preserve_space != style.preserve_space or entry.anchor != style.text_anchor or !text.sameFont(entry.font, style.font) or entry.viewport.width != frame.viewport.width or entry.viewport.height != frame.viewport.height) continue;
            if (entry.painted) |product| {
                var plan = try positioning.Plan.buildCached(self, self.allocator(), index, frame, (try product.mapping.view()).source.len);
                defer plan.deinit();
                if (!plan.mixedPaint()) continue;
                if (product.commands > (limits.commands -| self.commands -| self.extra_commands) / 2) return error.TextCapacityExceeded;
                try product.update(self, &plan);
                _ = try self.use(entry.path, entry.glyphs, entry.characters, entry.positions, entry.chunks);
                try self.usePaint(product);
                try work.check();
                return entry.path;
            }
            if (entry.span_style == null or positioning.sameInherited(entry.span_style.?.*, style)) return self.use(entry.path, entry.glyphs, entry.characters, entry.positions, entry.chunks);
        }
        if (self.len == self.entries.len) return error.TextInstancesFull;
        const a = self.allocator();
        var plan = try positioning.Plan.build(self, a, index, frame);
        defer plan.deinit();
        self.source_bytes += plan.source.items.len;
        var commands: std.ArrayList(v.Command) = .empty;
        defer commands.deinit(a);
        var cells: std.ArrayList(v.Bounds) = .empty;
        defer cells.deinit(a);
        var complete_cells = true;
        var glyphs: usize = 0;
        var cursor: v.Point = .{ .x = 0, .y = 0 };
        const provider = work.options.text_provider orelse return error.TextProviderRequired;
        for (plan.chunks.items) |chunk| {
            try work.check();
            if ((chunk.adjusted or plan.mixedPaint()) and !provider.supports_mapping) return error.UnsupportedTextMapping;
            const result = try provider.shape(provider.context, a, .{
                .utf8 = plan.source.items[chunk.start..chunk.end],
                .font = style.font,
                .max_glyphs = limits.glyphs - self.glyphs - glyphs,
                .max_commands = @min(limits.commands -| self.commands -| self.extra_commands, work.options.limits.path.commands) -| commands.items.len,
                .max_bytes = work.options.limits.bytes -| work.live,
                .cancellation = work.options.cancellation,
                .include_mapping = chunk.adjusted or plan.mixedPaint(),
                .max_work = limits.work -| self.used,
            });
            // Wrong-owner output remains the violating provider's obligation.
            result.path.checkOwner() catch return error.InvalidTextProviderOwner;
            var transferred = false;
            defer if (!transferred) result.path.close() catch unreachable;
            defer if (!transferred) {
                if (result.cells) |values| result.path.allocator.free(values);
            };
            var owned_mapping: ?*text.Mapping = null;
            if (result.mapping) |mapping| {
                _ = mapping.view() catch return error.InvalidTextProviderOwner;
                owned_mapping = mapping;
            }
            defer if (owned_mapping) |mapping| mapping.close() catch unreachable;
            if (result.path.allocator.ptr != a.ptr or result.path.allocator.vtable != a.vtable) return error.InvalidTextProviderAllocator;
            if (!std.math.isFinite(result.first_baseline) or @abs(result.first_baseline) > 1e9 or !std.math.isFinite(result.advance) or result.advance < 0 or result.advance > 1e9) return error.InvalidTextProviderMetrics;
            try self.charge(result.work);
            if (result.glyphs > limits.glyphs -| self.glyphs -| glyphs or result.path.commands.len > limits.commands -| self.commands -| commands.items.len or result.path.commands.len > work.options.limits.path.commands -| commands.items.len) return error.TextCapacityExceeded;
            if (result.cells) |values| {
                if (values.len != result.glyphs) return error.InvalidTextProviderCells;
                try self.charge(values.len);
                for (values) |cell| try validCell(cell);
            } else complete_cells = false;
            if (chunk.adjusted or plan.mixedPaint()) {
                const mapping = owned_mapping orelse return error.UnsupportedTextMapping;
                const mapped = try mapping.view();
                if (mapped.path == result.path) {
                    _ = try mapping.takePath();
                    owned_mapping = null;
                    return error.InvalidTextProviderMapping;
                }
                if (mapped.path.allocator.ptr != a.ptr or mapped.path.allocator.vtable != a.vtable) return error.InvalidTextProviderAllocator;
                if (mapped.glyphs.len != result.glyphs) return error.InvalidTextProviderMapping;
                if (mapped.path.commands.len > limits.commands -| self.commands -| self.extra_commands -| result.path.commands.len or mapped.path.commands.len > work.options.limits.path.commands) return error.TextCapacityExceeded;
                if (chunk.position.x) |x| cursor.x = x;
                if (chunk.position.y) |y| cursor.y = y;
                cursor.x += chunk.position.dx;
                cursor.y += chunk.position.dy;
                try v.validPoint(cursor);
                if (plan.mixedPaint()) {
                    self.extra_commands += result.path.commands.len;
                    if (mapped.path.commands.len > (limits.commands -| self.commands -| self.extra_commands) / 2) return error.TextCapacityExceeded;
                    const product = if (chunk.adjusted) placed: {
                        // The original mapped candidate is posed once. The
                        // cached Product subsequently updates only fill runs;
                        // source metadata never becomes a second pose pass.
                        const positioned = try adjustment.position(self, a, mapping, &plan, style.font, style.text_anchor, cursor, result.first_baseline);
                        errdefer a.free(positioned.quads);
                        break :placed try painting.Product.adoptPositioned(self, a, positioned, &plan);
                    } else unadjusted: {
                        const placement = (try adjustment.Horizontal.measure(result.advance, plan.text_length)).anchored(style.font.direction, style.text_anchor, cursor, result.first_baseline);
                        try v.validPoint(placement.offset);
                        break :unadjusted try painting.Product.create(self, a, mapping, &plan, style.font, placement);
                    };
                    owned_mapping = null;
                    var published = false;
                    defer if (!published) product.close();
                    if (result.cells) |values| result.path.allocator.free(values);
                    result.path.close() catch unreachable;
                    transferred = true;
                    try work.check();
                    const output = try self.publish(index, frame, &plan, try product.path(), product.alignedCells(), product.cellQuads(), result.glyphs, product);
                    published = true;
                    self.requests += 1;
                    self.mapping_requests += 1;
                    return output;
                }
                const quads = try adjustment.apply(self, a, mapped, &plan, style.font, style.text_anchor, cursor, result.first_baseline);
                errdefer a.free(quads);
                const path = try mapping.takePath();
                owned_mapping = null;
                var path_transferred = false;
                defer if (!path_transferred) path.close() catch unreachable;
                self.extra_commands += result.path.commands.len;
                // Complete foreign source/mapping cleanup before cache commit.
                if (result.cells) |values| result.path.allocator.free(values);
                result.path.close() catch unreachable;
                transferred = true;
                try work.check();
                const output = try self.publish(index, frame, &plan, path, null, quads, result.glyphs, null);
                path_transferred = true;
                self.requests += 1;
                self.mapping_requests += 1;
                return output;
            } else if (owned_mapping != null) return error.InvalidTextProviderMapping;
            const measured = try adjustment.Horizontal.measure(result.advance, plan.text_length);
            try measured.checkOutline(self, result.path.commands);
            if (chunk.position.x) |x| cursor.x = x;
            if (chunk.position.y) |y| cursor.y = y;
            cursor.x += chunk.position.dx;
            cursor.y += chunk.position.dy;
            try v.validPoint(cursor);
            const placement = measured.anchored(style.font.direction, style.text_anchor, cursor, result.first_baseline);
            try placement.apply(self, result.path.commands);
            if (result.cells) |values| {
                for (values) |*cell| {
                    placement.cell(cell);
                    try validCell(cell.*);
                }
            }
            // Ordinary text and markup-only spans retain the original outline
            // allocation. Only real positioned chunks need an aggregate copy.
            if (plan.chunks.items.len == 1) {
                try work.check();
                const output = try self.publish(index, frame, &plan, result.path, result.cells, null, result.glyphs, null);
                transferred = true;
                self.requests += 1;
                return output;
            }
            try commands.appendSlice(a, result.path.commands);
            if (result.cells) |values| if (complete_cells) try cells.appendSlice(a, values);
            cursor.x += if (style.font.direction == .rtl) -measured.advance else measured.advance;
            try v.validPoint(cursor);
            glyphs += result.glyphs;
            self.requests += 1;
            try work.check();
        }
        const path = try v.Path.create(a, commands.items, work.options.limits.path);
        errdefer path.close() catch unreachable;
        const owned_cells = if (complete_cells) try a.dupe(v.Bounds, cells.items) else null;
        errdefer if (owned_cells) |values| a.free(values);
        return self.publish(index, frame, &plan, path, owned_cells, null, glyphs, null);
    }
    /// On success the cache owns path/cells; on failure the caller still does.
    fn publish(self: *Cache, index: usize, frame: pre.Frame, plan: *const positioning.Plan, path: *v.Path, owned_cells: ?[]v.Bounds, quads: ?[]adjustment.Quad, glyphs: usize, painted: ?*painting.Product) !*v.Path {
        const a = self.allocator();
        const style = frame.style;
        const span_style = if (plan.elements.items.len > 1) try a.create(styles.Style) else null;
        errdefer if (span_style) |value| a.destroy(value);
        if (span_style) |value| value.* = style;
        // A uniform descendant fill still uses the original batch outline.
        // Only this uncommon override owns an extra value; ordinary roots
        // retain their current instance paint without a mapping or a copy.
        var uniform_fill: ?*painting.Fill = null;
        errdefer if (uniform_fill) |value| a.destroy(value);
        if (painted == null) if (plan.first_fill) |value| {
            if (!painting.Fill.same(value, painting.Fill.from(style))) {
                uniform_fill = try a.create(painting.Fill);
                uniform_fill.?.* = value;
            }
        };
        try self.work.check();
        _ = try self.use(path, glyphs, plan.character_count, plan.position_count, plan.chunks.items.len);
        if (painted) |product| try self.usePaint(product);
        self.entries[self.len] = .{ .index = index, .font = style.font, .anchor = style.text_anchor, .preserve_space = style.preserve_space, .span_style = span_style, .viewport = frame.viewport, .path = path, .glyphs = glyphs, .cells = owned_cells, .quads = quads, .characters = plan.character_count, .positions = plan.position_count, .chunks = plan.chunks.items.len, .painted = painted, .uniform_fill = uniform_fill };
        self.len += 1;
        return path;
    }
    fn allocator(self: *Cache) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Cache = @ptrCast(@alignCast(context));
        const work = self.work;
        if (!work.allocator_budgeted) work.reserve(length) catch {
            self.denied = true;
            return null;
        };
        const bytes = work.allocator.rawAlloc(length, alignment, ret) orelse {
            if (!work.allocator_budgeted) work.live -= length;
            return null;
        };
        return bytes;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Cache = @ptrCast(@alignCast(context));
        const work = self.work;
        work.allocator.rawFree(bytes, alignment, ret);
        if (!work.allocator_budgeted) work.live -= bytes.len;
    }
};
fn validCell(cell: v.Bounds) !void {
    if (!std.math.isFinite(cell.width) or !std.math.isFinite(cell.height) or cell.width < 0 or cell.height < 0) return error.InvalidTextProviderCells;
    v.validPoint(.{ .x = cell.x, .y = cell.y }) catch return error.InvalidTextProviderCells;
    v.validPoint(.{ .x = cell.x + cell.width, .y = cell.y + cell.height }) catch return error.InvalidTextProviderCells;
}
