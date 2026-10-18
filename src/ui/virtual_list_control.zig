const std = @import("std");
const selection_words = @import("virtual_list_selection.zig");

/// Private opt-in state. The accepted model still lives in exactly one List.
pub fn Control(comptime Access: type) type {
    return struct {
        const Self = @This();
        pub const Row = Access.Row;
        pub const Token = struct { id: u64, incarnation: u64 };
        pub const Stamp = struct { model: u64, state: u64 };
        pub const Selection = enum { replace, toggle, extend, add_extend };
        pub const Navigation = enum { previous, next, first, last, page_previous, page_next };
        pub const NavigationSelection = enum { replace, caret_only, extend, add_extend };
        pub const Options = struct {
            list: Access.Limits = .{},
            bytes: usize = 16 * 1024 * 1024,
            peak_bytes: usize = 32 * 1024 * 1024,
        };
        pub const Change = struct { selection: bool = false, caret: bool = false, anchor: bool = false };
        pub const Move = struct { change: Change, scroll: f64 };
        pub const Cursor = struct { stamp: Stamp, next_index: usize = 0 };
        pub const DragToken = struct { serial: u64 };
        pub const SelectionPatch = struct { model: u64, delta: selection_words.Patch };
        const Interval = struct { first: usize, end: usize };
        const Drag = struct { serial: u64, model: u64, anchor: Token, interval: Interval };

        allocator: std.mem.Allocator,
        thread: std.Thread.Id,
        list: *Access.List,
        options: Options,
        selection: selection_words.Words,
        incarnations: []u64,
        patch_model_revision: u64 = 1,
        anchor_row: ?Token = null,
        caret_row: ?Token = null,
        model_revision: u64 = 1,
        state_revision: u64 = 1,
        incarnation: u64 = 0,
        drag_serial: u64 = 0,
        drag: ?Drag = null,
        busy: bool = false,
        closing: bool = false,

        fn arrayBytes(count: usize) !usize {
            return std.math.add(usize, try std.math.mul(usize, count, @sizeOf(u64)), try selection_words.Words.arrayBytes(count));
        }
        fn check(self: *const Self) !void {
            if (std.Thread.getCurrentId() != self.thread) return error.WrongThread;
            if (self.closing) return error.Closed;
        }
        fn mutation(self: *Self) !void {
            try self.check();
            if (self.busy) return error.Busy;
            if (self.state_revision == std.math.maxInt(u64)) return error.IdExhausted;
        }
        fn validateBudget(options: Options, count: usize, old_arrays: usize) !void {
            if (options.bytes < @sizeOf(Self) or options.bytes > 16 * 1024 * 1024 or options.peak_bytes < options.bytes or options.peak_bytes > 32 * 1024 * 1024) return error.InvalidControlLimits;
            const candidate = try arrayBytes(count);
            if (try std.math.add(usize, @sizeOf(Self), candidate) > options.bytes or try std.math.add(usize, @sizeOf(Self), try std.math.add(usize, old_arrays, candidate)) > options.peak_bytes) return error.ControlBudgetExceeded;
        }
        pub fn create(allocator: std.mem.Allocator, thread: std.Thread.Id, rows: []const Row, options: Options) !*Self {
            return createFrozen(allocator.ptr, allocator.vtable, thread, rows.ptr, rows.len, options.list.rows, options.list.owned_bytes, options.list.peak_bytes, options.bytes, options.peak_bytes);
        }
        noinline fn createFrozen(allocator_ptr: *anyopaque, allocator_vtable: *const std.mem.Allocator.VTable, thread: std.Thread.Id, rows_ptr: [*]const Row, row_count: usize, list_rows: usize, list_bytes: usize, list_peak: usize, bytes: usize, peak_bytes: usize) !*Self {
            const allocator: std.mem.Allocator = .{ .ptr = allocator_ptr, .vtable = allocator_vtable };
            const rows = rows_ptr[0..row_count];
            const options: Options = .{ .list = .{ .rows = list_rows, .owned_bytes = list_bytes, .peak_bytes = list_peak }, .bytes = bytes, .peak_bytes = peak_bytes };
            if (std.Thread.getCurrentId() != thread) return error.WrongThread;
            try validateBudget(options, rows.len, 0);
            const list = try Access.create(allocator, thread, rows, options.list);
            errdefer list.close() catch unreachable;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            var selection = try selection_words.Words.create(allocator, rows.len, 1);
            errdefer selection.close();
            const incarnations = try allocator.alloc(u64, rows.len);
            errdefer allocator.free(incarnations);
            for (incarnations, 0..) |*value, index| value.* = @intCast(index + 1);
            self.* = .{ .allocator = allocator, .thread = thread, .list = list, .options = options, .selection = selection, .incarnations = incarnations, .incarnation = @intCast(rows.len) };
            return self;
        }
        pub fn close(self: *Self) !void {
            try self.check();
            if (self.busy) return error.Busy;
            self.closing = true;
            const allocator = self.allocator;
            const list = self.list;
            var selection = self.selection;
            const incarnations = self.incarnations;
            list.close() catch unreachable;
            selection.close();
            allocator.free(incarnations);
            allocator.destroy(self);
        }
        pub fn model(self: *const Self) !*const Access.List {
            try self.check();
            return self.list;
        }
        pub fn stamp(self: *const Self) !Stamp {
            try self.check();
            return .{ .model = self.model_revision, .state = self.state_revision };
        }
        pub fn validateStamp(self: *const Self, expected: Stamp) !void {
            if (!std.meta.eql(try self.stamp(), expected)) return error.StaleControlEvent;
        }
        pub fn tokenAt(self: *const Self, index: usize) !Token {
            try self.check();
            const row = try self.list.row(index);
            return .{ .id = row.id, .incarnation = self.incarnations[index] };
        }
        pub fn token(self: *const Self, id: u64) !Token {
            try self.check();
            return self.tokenAt((try self.list.indexOf(id)) orelse return error.UnknownRow);
        }
        pub fn resolve(self: *const Self, value: Token) !usize {
            try self.check();
            const index = (try self.list.indexOf(value.id)) orelse return error.StaleRow;
            if (value.incarnation == 0 or self.incarnations[index] != value.incarnation) return error.StaleRow;
            return index;
        }
        pub fn selectedCount(self: *const Self) !usize {
            try self.check();
            return self.selection.selected_count;
        }
        pub fn selectedAt(self: *const Self, index: usize) !bool {
            try self.check();
            if (index >= self.incarnations.len) return error.InvalidIndex;
            return self.selection.contains(index);
        }
        pub fn selected(self: *const Self, id: u64) !bool {
            try self.check();
            return self.selectedAt((try self.list.indexOf(id)) orelse return error.UnknownRow);
        }
        pub fn caret(self: *const Self) !?Token {
            try self.check();
            return self.caret_row;
        }
        pub fn anchor(self: *const Self) !?Token {
            try self.check();
            return self.anchor_row;
        }
        fn interval(self: *Self, range: Interval, restore: bool) void {
            // Disjoint symmetric-difference segments may be reversed.
            if (range.first >= range.end) return;
            self.selection.range(range.first, range.end, restore);
        }
        fn rowInterval(a: usize, b: usize) Interval {
            return .{ .first = @min(a, b), .end = @max(a, b) + 1 };
        }
        fn changes(self: *Self, old_caret: ?Token, old_anchor: ?Token) Change {
            const patch = self.selection.finish();
            self.patch_model_revision = self.model_revision;
            return .{ .selection = patch.words.len != 0, .caret = !std.meta.eql(old_caret, self.caret_row), .anchor = !std.meta.eql(old_anchor, self.anchor_row) };
        }
        pub fn selectionPatch(self: *const Self) !SelectionPatch {
            try self.check();
            if (self.patch_model_revision != self.model_revision) return error.CatalogRequired;
            return .{ .model = self.patch_model_revision, .delta = try self.selection.patch() };
        }
        pub fn arrayStorageBytes(self: *const Self) !usize {
            try self.check();
            return arrayBytes(self.incarnations.len);
        }
        pub fn select(self: *Self, target: Token, mode: Selection) !Change {
            try self.mutation();
            const index = try self.resolve(target);
            const anchor_row = self.anchor_row orelse self.caret_row orelse target;
            const anchor_index = try self.resolve(anchor_row);
            const old_caret = self.caret_row;
            const old_anchor = self.anchor_row;
            try self.selection.begin();
            self.drag = null;
            switch (mode) {
                .replace => {
                    self.selection.clear();
                    self.interval(.{ .first = index, .end = index + 1 }, false);
                    self.anchor_row = target;
                },
                .toggle => {
                    self.selection.toggle(index);
                    self.anchor_row = target;
                },
                .extend, .add_extend => {
                    const range = rowInterval(anchor_index, index);
                    if (mode == .extend) self.selection.clear();
                    self.interval(range, false);
                    self.anchor_row = anchor_row;
                },
            }
            self.caret_row = target;
            self.state_revision += 1;
            return self.changes(old_caret, old_anchor);
        }
        pub fn selectAll(self: *Self) !Change {
            try self.mutation();
            const old_caret = self.caret_row;
            const old_anchor = self.anchor_row;
            const first = if (self.incarnations.len == 0) null else try self.tokenAt(0);
            try self.selection.begin();
            self.drag = null;
            self.interval(.{ .first = 0, .end = self.incarnations.len }, false);
            if (first != null) {
                self.caret_row = self.caret_row orelse first;
                self.anchor_row = self.anchor_row orelse self.caret_row;
            }
            self.state_revision += 1;
            return self.changes(old_caret, old_anchor);
        }
        pub fn clear(self: *Self) !Change {
            try self.mutation();
            const old_anchor = self.anchor_row;
            const old_caret = self.caret_row;
            try self.selection.begin();
            self.drag = null;
            self.selection.clear();
            self.anchor_row = null;
            self.state_revision += 1;
            return self.changes(old_caret, old_anchor);
        }
        pub fn contextSelect(self: *Self, target: Token) !Change {
            try self.mutation();
            const index = try self.resolve(target);
            if (!self.selection.contains(index)) return self.select(target, .replace);
            const old = self.caret_row;
            self.drag = null;
            self.caret_row = target;
            self.state_revision += 1;
            return .{ .caret = !std.meta.eql(old, self.caret_row) };
        }
        pub fn focusRow(self: *Self, target: Token) !Change {
            try self.mutation();
            _ = try self.resolve(target);
            const old = self.caret_row;
            self.drag = null;
            self.caret_row = target;
            self.state_revision += 1;
            return .{ .caret = !std.meta.eql(old, self.caret_row) };
        }
        pub fn cursor(self: *const Self) !Cursor {
            return .{ .stamp = try self.stamp() };
        }
        pub fn nextSelected(self: *const Self, current: *Cursor) !?Token {
            try self.validateStamp(current.stamp);
            var index = current.next_index;
            while (index < self.incarnations.len) {
                const word = self.selection.bits[index / 64] & (@as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(index % 64)));
                if (word != 0) {
                    index = index / 64 * 64 + @ctz(word);
                    current.next_index = index + 1;
                    return try self.tokenAt(index);
                }
                index = (index / 64 + 1) * 64;
            }
            current.next_index = self.incarnations.len;
            return null;
        }
        pub fn setHeight(self: *Self, id: u64, height: f32) !bool {
            try self.mutation();
            if (self.model_revision == std.math.maxInt(u64)) return error.IdExhausted;
            const changed = try self.list.setHeight(id, height);
            if (changed) {
                self.model_revision += 1;
                self.state_revision += 1;
                self.drag = null;
                self.patch_model_revision = 0;
            }
            return changed;
        }
        pub fn replace(self: *Self, rows: []const Row) !void {
            try self.mutation();
            if (self.model_revision == std.math.maxInt(u64) or self.selection.revision == std.math.maxInt(u64)) return error.IdExhausted;
            try validateBudget(self.options, rows.len, try arrayBytes(self.incarnations.len));
            self.busy = true;
            defer self.busy = false;
            var candidate = try Access.prepare(self.list, rows);
            errdefer Access.release(self.list, &candidate);
            var selection = try selection_words.Words.create(self.allocator, rows.len, self.selection.revision + 1);
            errdefer selection.close();
            const incarnations = try self.allocator.alloc(u64, rows.len);
            errdefer self.allocator.free(incarnations);
            var serial = self.incarnation;
            const previous_ids = Access.identities(self.list);
            const next_ids = Access.candidateIdentities(&candidate);
            var previous_index: usize = 0;
            var anchor_row: ?Token = null;
            var caret_row: ?Token = null;
            for (next_ids) |entry| {
                while (previous_index < previous_ids.len and previous_ids[previous_index].id < entry.id) previous_index += 1;
                if (previous_index < previous_ids.len and previous_ids[previous_index].id == entry.id) {
                    const previous = previous_ids[previous_index];
                    incarnations[entry.index] = self.incarnations[previous.index];
                    if (self.selection.contains(previous.index)) selection.initialSelect(entry.index);
                    if (self.anchor_row) |value| if (value.id == entry.id) {
                        anchor_row = value;
                    };
                    if (self.caret_row) |value| if (value.id == entry.id) {
                        caret_row = value;
                    };
                } else {
                    if (serial == std.math.maxInt(u64)) return error.IdExhausted;
                    serial += 1;
                    incarnations[entry.index] = serial;
                }
            }
            var old_selection = self.selection;
            const old_incarnations = self.incarnations;
            var old_index = Access.publish(self.list, candidate);
            self.selection = selection;
            self.incarnations = incarnations;
            self.incarnation = serial;
            self.anchor_row = anchor_row;
            self.caret_row = caret_row;
            self.model_revision += 1;
            self.state_revision += 1;
            self.drag = null;
            self.patch_model_revision = 0;
            Access.release(self.list, &old_index);
            old_selection.close();
            self.allocator.free(old_incarnations);
        }
        pub fn navigate(self: *Self, direction: Navigation, selection: NavigationSelection, scroll: f64, viewport: f64) !Move {
            try self.mutation();
            _ = try self.list.clampScroll(scroll, viewport);
            const count = self.incarnations.len;
            if (count == 0) return .{ .change = .{}, .scroll = 0 };
            const current = if (self.caret_row) |value| try self.resolve(value) else null;
            const index: usize = switch (direction) {
                .first => 0,
                .last => count - 1,
                .previous => if (current) |value| value -| 1 else count - 1,
                .next => if (current) |value| @min(value + 1, count - 1) else 0,
                .page_previous, .page_next => value: {
                    if (viewport == 0) return error.EmptyViewport;
                    const origin = if (current) |at| try self.list.rowTop(at) else if (direction == .page_next) @as(f64, 0) else try self.list.totalHeight();
                    const at = try self.list.anchor(origin + if (direction == .page_next) viewport else -viewport, 0);
                    break :value at.old_index;
                },
            };
            const target = try self.tokenAt(index);
            const next_scroll = try self.list.reveal(target.id, scroll, viewport, .nearest);
            const change = if (selection == .caret_only) value: {
                const old = self.caret_row;
                self.caret_row = target;
                self.drag = null;
                self.state_revision += 1;
                break :value Change{ .caret = !std.meta.eql(old, self.caret_row) };
            } else try self.select(target, switch (selection) {
                .replace => .replace,
                .extend => .extend,
                .add_extend => .add_extend,
                .caret_only => unreachable,
            });
            return .{ .change = change, .scroll = next_scroll };
        }
        pub fn beginDrag(self: *Self, target: Token, mode: Selection) !struct { token: DragToken, change: Change } {
            try self.mutation();
            if (mode == .toggle) return error.InvalidDragMode;
            if (self.drag_serial == std.math.maxInt(u64)) return error.IdExhausted;
            const index = try self.resolve(target);
            const anchor_row = if (mode == .replace) target else self.anchor_row orelse self.caret_row orelse target;
            const anchor_index = try self.resolve(anchor_row);
            try self.selection.checkBegin();
            self.selection.captureBase(mode == .add_extend);
            // select does not touch the base. Subsequent motion restores only
            // the symmetric difference from this captured base selection.
            const change = try self.select(target, mode);
            self.drag_serial += 1;
            self.drag = .{ .serial = self.drag_serial, .model = self.model_revision, .anchor = anchor_row, .interval = rowInterval(anchor_index, index) };
            return .{ .token = .{ .serial = self.drag_serial }, .change = change };
        }
        pub fn updateDrag(self: *Self, token_value: DragToken, target: Token) !Change {
            try self.mutation();
            const drag = self.drag orelse return error.StaleDrag;
            if (token_value.serial == 0 or token_value.serial != drag.serial or drag.model != self.model_revision) return error.StaleDrag;
            const next = rowInterval(try self.resolve(drag.anchor), try self.resolve(target));
            const previous = drag.interval;
            try self.selection.begin();
            self.interval(.{ .first = previous.first, .end = @min(previous.end, next.first) }, true);
            self.interval(.{ .first = @max(previous.first, next.end), .end = previous.end }, true);
            self.interval(.{ .first = next.first, .end = @min(next.end, previous.first) }, false);
            self.interval(.{ .first = @max(next.first, previous.end), .end = next.end }, false);
            const old_caret = self.caret_row;
            self.caret_row = target;
            self.drag.?.interval = next;
            self.state_revision += 1;
            return self.changes(old_caret, self.anchor_row);
        }
        /// Cancelling the gesture keeps already accepted business selection.
        pub fn cancelDrag(self: *Self, token_value: DragToken) !void {
            try self.mutation();
            const drag = self.drag orelse return error.StaleDrag;
            if (token_value.serial != drag.serial) return error.StaleDrag;
            self.drag = null;
            self.state_revision += 1;
        }
    };
}
