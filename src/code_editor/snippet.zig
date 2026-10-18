const std = @import("std");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
pub const parser = @import("snippet_parser.zig");
pub const Template = parser.Template;
pub const ParseLimits = parser.Limits;
pub const ParseOptions = parser.ParseOptions;
pub const Resolver = parser.Resolver;
pub const ValueWriter = parser.ValueWriter;
pub const Resolution = parser.Resolution;
pub const Cancellation = parser.Cancellation;
pub const TransformRuntimeLimits = struct { runtime: parser.transform.RuntimeLimits = .{}, results_bytes: usize = 65536, cancellation: ?*const Cancellation = null };
pub const Limits = struct { occurrences: usize = 512, insertions: usize = 64, bytes: usize = 512 * 1024, replacement_bytes: usize = 1024 * 1024, work: usize = 1024 * 1024, transforms: ?TransformRuntimeLimits = null };
pub const Outcome = struct { committed: bool = false, committed_revision: ?u64 = null, active: bool, revision: u64, stale_after_commit: bool = false };
pub const Status = struct { active: bool, id: ?u16, occurrences: usize, revision: u64, owned_bytes: usize };
const Occurrence = struct { id: u16, range: d.Range, instance: usize, ordinal: usize, parent: ?usize = null, live: bool = true, transform_index: ?usize = null };

/// Owner-thread update-phase session. The Adapter/Document are the sole text,
/// selection and history owners. This stores only bounded derived byte ranges.
/// Hosts explicitly route snippet input before normal editor input once.
pub const Session = SessionFor(editing.Adapter);

fn SessionFor(comptime Target: type) type {
    return struct {
        pub const Owner = opaque {
            pub fn create(allocator: std.mem.Allocator, adapter: *Target, limits: Limits) !*Owner {
                const document = if (Target == d.Document) adapter else try adapter.sourceDocument();
                if (limits.occurrences == 0 or limits.occurrences > 4096 or limits.insertions == 0 or limits.insertions > 256 or limits.replacement_bytes > 16 * 1024 * 1024 or limits.bytes > 16 * 1024 * 1024 or limits.work == 0 or limits.work > 32 * 1024 * 1024) return error.InvalidLimits;
                var owned = @sizeOf(State) + limits.occurrences * (2 * @sizeOf(Occurrence) + @sizeOf(d.Replacement) + @sizeOf(d.Selection) + @sizeOf(usize));
                if (limits.transforms) |transforms| {
                    if (transforms.results_bytes > 16 * 1024 * 1024) return error.InvalidLimits;
                    const runtime_bytes = try parser.transform.Runtime.requiredBytes(transforms.runtime);
                    for ([_]usize{ runtime_bytes - @sizeOf(parser.transform.Runtime), transforms.results_bytes, transforms.runtime.input_bytes }) |part| owned = std.math.add(usize, owned, part) catch return error.CapacityExceeded;
                }
                if (owned > limits.bytes) return error.CapacityExceeded;
                try adapter.retainClient();
                errdefer adapter.releaseClient() catch unreachable;
                const state = try allocator.create(State);
                errdefer allocator.destroy(state);
                const first = try allocator.alloc(Occurrence, limits.occurrences);
                errdefer allocator.free(first);
                const second = try allocator.alloc(Occurrence, limits.occurrences);
                errdefer allocator.free(second);
                const edits = try allocator.alloc(d.Replacement, limits.occurrences);
                errdefer allocator.free(edits);
                const selections = try allocator.alloc(d.Selection, limits.occurrences);
                errdefer allocator.free(selections);
                const indices = try allocator.alloc(usize, limits.occurrences);
                errdefer allocator.free(indices);
                var runtime: ?parser.transform.Runtime = null;
                errdefer if (runtime) |*value| value.deinit() catch unreachable;
                var input: []u8 = &.{};
                errdefer allocator.free(input);
                var results: []u8 = &.{};
                if (limits.transforms) |transforms| {
                    runtime = try parser.transform.Runtime.init(allocator, transforms.runtime);
                    input = try allocator.alloc(u8, transforms.runtime.input_bytes);
                    results = try allocator.alloc(u8, transforms.results_bytes);
                }
                state.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .adapter = adapter, .document = document, .limits = limits, .ranges = .{ first, second }, .edits = edits, .selections = selections, .indices = indices, .owned = owned, .transform_runtime = runtime, .transform_input = input, .transform_results = results };
                return @ptrCast(state);
            }
            /// Borrowed by an owning presenter; prevents foreign cleanup from
            /// destroying the session between preparation and transaction entry.
            pub fn retainClient(self: *Owner) !void {
                const state = cast(self);
                try state.check();
                state.clients = std.math.add(usize, state.clients, 1) catch return error.CapacityExceeded;
            }
            pub fn releaseClient(self: *Owner) !void {
                const state = cast(self);
                try state.check();
                if (state.clients == 0) return error.InvalidClient;
                state.clients -= 1;
            }
            pub const Preparation = struct {
                state: *State,
                live: bool = true,
                pub fn end(self: *Preparation) void {
                    if (!self.live) return;
                    std.debug.assert(self.state.owner == std.Thread.getCurrentId());
                    self.live = false;
                    std.debug.assert(self.state.busy);
                    self.state.busy = false;
                }
            };
            /// Explicit callback gate, not a second editable session. Linear
            /// owner-thread scope, held through the final preparation cleanup.
            pub fn beginPreparation(self: *Owner) !Preparation {
                const state = cast(self);
                try state.enter();
                if (state.pin != null) {
                    state.busy = false;
                    return error.AlreadyActive;
                }
                return .{ .state = state };
            }
            /// Insert an independent expansion at each sorted, disjoint original range.
            /// primary identifies the insertion whose declared placeholder is primary.
            pub fn start(self: *Owner, template: *Template, expected_revision: u64, ranges: []const d.Range, primary: usize) !Outcome {
                const state = cast(self);
                try state.enter();
                defer state.busy = false;
                if (state.pin != null) return error.AlreadyActive;
                if (try state.document.composition() != null) return error.CompositionActive;
                if (try state.document.version() != expected_revision) return error.StaleRevision;
                if (ranges.len == 0 or primary >= ranges.len) return error.InvalidSelections;
                if (ranges.len > state.limits.insertions) return error.CapacityExceeded;
                const pin = try template.borrow();
                var retained = false;
                defer if (!retained) pin.end();
                const view = pin.data;
                try state.validateTransforms(view);
                if (view.text.len > state.limits.replacement_bytes or view.occurrences.len > state.limits.occurrences / ranges.len) return error.CapacityExceeded;
                if (view.occurrences.len * ranges.len > state.limits.work) return error.WorkExceeded;
                const id = view.stops[0].id;
                const canonical = view.stops[0].primary;
                var old_end: usize = 0;
                var new_end: usize = 0;
                var previous: ?d.Range = null;
                const candidate = state.ranges[state.front ^ 1];
                var count: usize = 0;
                for (ranges, 0..) |range, instance| {
                    if (range.start > range.end) return error.InvalidRange;
                    _ = try state.document.utf16Offset(range.start);
                    _ = try state.document.utf16Offset(range.end);
                    if (previous) |before| if (range.start <= before.start or range.start < before.end or (range.start == before.end and (range.start == range.end or before.start == before.end))) return error.OverlappingEdits;
                    previous = range;
                    const insertion_start = std.math.add(usize, new_end, range.start - old_end) catch return error.CapacityExceeded;
                    const instance_base = count;
                    for (view.occurrences, 0..) |occurrence, ordinal| {
                        candidate[count] = .{ .id = occurrence.id, .range = .{ .start = std.math.add(usize, insertion_start, occurrence.range.start) catch return error.CapacityExceeded, .end = std.math.add(usize, insertion_start, occurrence.range.end) catch return error.CapacityExceeded }, .instance = instance, .ordinal = ordinal, .parent = if (occurrence.parent) |parent| instance_base + parent else null, .transform_index = occurrence.transform_index };
                        count += 1;
                    }
                    state.edits[instance] = .{ .range = range, .text = view.text };
                    old_end = range.end;
                    new_end = std.math.add(usize, insertion_start, view.text.len) catch return error.CapacityExceeded;
                }
                const selected = try state.selectCandidate(candidate[0..count], id, primary, canonical, null);
                const committed_revision = std.math.add(u64, expected_revision, 1) catch return error.IdExhausted;
                _ = try state.adapter.replaceManyWithSelections(expected_revision, state.edits[0..ranges.len], state.selections[0..selected.count], selected.primary);
                const revision = try state.document.version();
                if (revision != committed_revision or try state.document.composition() != null) return .{ .committed = true, .committed_revision = committed_revision, .active = false, .revision = revision, .stale_after_commit = true };
                state.front ^= 1;
                state.count = count;
                state.revision = revision;
                state.primary_instance = primary;
                state.active_id = id;
                if (id != 0) {
                    state.pin = pin;
                    retained = true;
                } else state.count = 0;
                return .{ .committed = true, .committed_revision = committed_revision, .active = id != 0, .revision = revision };
            }
            /// One template edit plus literal additional edits, all in original
            /// coordinates. The final mirrors include preceding literal deltas.
            pub fn startCompletion(self: *Owner, template: *Template, expected_revision: u64, edits: []const d.Replacement, snippet_index: usize) !Outcome {
                const state = cast(self);
                try state.enter();
                defer state.busy = false;
                if (state.pin != null) return error.AlreadyActive;
                if (try state.document.composition() != null) return error.CompositionActive;
                if (try state.document.version() != expected_revision) return error.StaleRevision;
                if (snippet_index >= edits.len) return error.InvalidSnippetEdit;
                if (edits.len > state.limits.insertions or edits.len > state.edits.len) return error.CapacityExceeded;
                const pin = try template.borrow();
                var retained = false;
                defer if (!retained) pin.end();
                const view = pin.data;
                try state.validateTransforms(view);
                if (view.text.len > state.limits.replacement_bytes or view.occurrences.len > state.limits.occurrences) return error.CapacityExceeded;
                if (view.occurrences.len + edits.len > state.limits.work) return error.WorkExceeded;
                var previous: ?d.Range = null;
                var old_end: usize = 0;
                var new_end: usize = 0;
                var snippet_start: usize = 0;
                for (edits, 0..) |replacement, index| {
                    const range = replacement.range;
                    if (range.start > range.end) return error.InvalidRange;
                    _ = try state.document.utf16Offset(range.start);
                    _ = try state.document.utf16Offset(range.end);
                    if (previous) |before| if (range.start <= before.start or range.start < before.end or (range.start == before.end and (range.start == range.end or before.start == before.end))) return error.OverlappingEdits;
                    previous = range;
                    const inserted = if (index == snippet_index) view.text else replacement.text;
                    if (inserted.len > state.limits.replacement_bytes) return error.CapacityExceeded;
                    const begin = std.math.add(usize, new_end, range.start - old_end) catch return error.CapacityExceeded;
                    if (index == snippet_index) snippet_start = begin;
                    new_end = std.math.add(usize, begin, inserted.len) catch return error.CapacityExceeded;
                    old_end = range.end;
                    state.edits[index] = .{ .range = range, .text = inserted };
                }
                const candidate = state.ranges[state.front ^ 1][0..view.occurrences.len];
                for (candidate, view.occurrences, 0..) |*target, occurrence, ordinal| target.* = .{ .id = occurrence.id, .range = .{ .start = std.math.add(usize, snippet_start, occurrence.range.start) catch return error.CapacityExceeded, .end = std.math.add(usize, snippet_start, occurrence.range.end) catch return error.CapacityExceeded }, .instance = 0, .ordinal = ordinal, .parent = occurrence.parent, .transform_index = occurrence.transform_index };
                const id = view.stops[0].id;
                const selected = try state.selectCandidate(candidate, id, 0, view.stops[0].primary, null);
                const committed_revision = std.math.add(u64, expected_revision, 1) catch return error.IdExhausted;
                _ = try state.adapter.replaceManyWithSelections(expected_revision, state.edits[0..edits.len], state.selections[0..selected.count], selected.primary);
                const revision = try state.document.version();
                if (revision != committed_revision or try state.document.composition() != null) return .{ .committed = true, .committed_revision = committed_revision, .active = false, .revision = revision, .stale_after_commit = true };
                state.front ^= 1;
                state.count = candidate.len;
                state.revision = revision;
                state.primary_instance = 0;
                state.active_id = id;
                if (id != 0) {
                    state.pin = pin;
                    retained = true;
                } else state.count = 0;
                return .{ .committed = true, .committed_revision = committed_revision, .active = id != 0, .revision = revision };
            }
            pub fn status(self: *const Owner) !Status {
                const state = cast(@constCast(self));
                try state.check();
                var live: usize = 0;
                for (state.ranges[state.front][0..state.count]) |item| if (item.live) {
                    live += 1;
                };
                return .{ .active = state.pin != null, .id = if (state.pin != null) state.active_id else null, .occurrences = live, .revision = state.revision, .owned_bytes = state.owned };
            }
            /// Replace selected relative text in all active mirrors once. After commit
            /// each mirror has a collapsed caret after its inserted text.
            pub fn edit(self: *Owner, text: []const u8) !Outcome {
                const state = cast(self);
                try state.enter();
                defer state.busy = false;
                try state.current();
                const selected = try state.document.selections(state.selections);
                var relative: ?d.Selection = null;
                var identical = true;
                var whole = true;
                var at: usize = 0;
                for (state.ranges[state.front][0..state.count]) |item| if (item.live and item.id == state.active_id) {
                    if (at == selected.items.len) return error.InvalidSnippetSelection;
                    const selection = selected.items[at];
                    const range = selection.range();
                    if (range.start < item.range.start or range.end > item.range.end) return error.InvalidSnippetSelection;
                    const value: d.Selection = .{ .anchor = selection.anchor - item.range.start, .caret = selection.caret - item.range.start };
                    whole = whole and range.start == item.range.start and range.end == item.range.end;
                    if (relative) |before| {
                        identical = identical and std.meta.eql(before, value);
                    } else relative = value;
                    at += 1;
                };
                if (at != selected.items.len or relative == null) return error.InvalidSnippetSelection;
                if (!whole and !identical) return error.InvalidSnippetSelection;
                return state.replace(relative.?.range(), text, false, whole);
            }
            /// Explicit full-value replacement, independent of the current caret.
            pub fn replaceActive(self: *Owner, text: []const u8) !Outcome {
                const state = cast(self);
                try state.enter();
                defer state.busy = false;
                try state.current();
                const item = state.firstActive();
                return state.replace(.{ .start = 0, .end = item.range.end - item.range.start }, text, true, true);
            }
            pub fn choose(self: *Owner, index: usize) !Outcome {
                const state = cast(self);
                try state.enter();
                defer state.busy = false;
                try state.current();
                const text = try state.pin.?.data.choice(state.active_id, index);
                const item = state.firstActive();
                return state.replace(.{ .start = 0, .end = item.range.end - item.range.start }, text, true, true);
            }
            /// Explicit local selection is mirrored; unrelated Adapter selection edits
            /// deliberately stale the session instead of guessing a new active range.
            pub fn selectActive(self: *Owner, relative: d.Selection) !Outcome {
                const state = cast(self);
                try state.enter();
                defer state.busy = false;
                try state.current();
                const stop = state.pin.?.data.stop(state.active_id).?;
                const selected = try state.selectCandidate(state.ranges[state.front][0..state.count], state.active_id, state.primary_instance, stop.primary, relative);
                const changed = try state.adapter.setSelections(state.selections[0..selected.count], selected.primary);
                return state.afterSelection(changed);
            }
            pub fn next(self: *Owner, backwards: bool) !Outcome {
                const state = cast(self);
                try state.enter();
                defer state.busy = false;
                try state.current();
                const stops = state.pin.?.data.stops;
                const index = for (stops, 0..) |stop, at| {
                    if (stop.id == state.active_id) break at;
                } else unreachable;
                var chosen_index = index;
                while (true) {
                    if (backwards) {
                        if (chosen_index == 0) {
                            chosen_index = index;
                            break;
                        }
                        chosen_index -= 1;
                    } else chosen_index += 1;
                    const exists = for (state.ranges[state.front][0..state.count]) |item| {
                        if (item.live and item.id == stops[chosen_index].id) break true;
                    } else false;
                    if (exists) break;
                }
                const chosen = stops[chosen_index];
                return state.navigate(chosen, chosen_index != index);
            }
            /// Cancel changes no document state/history. It also closes stale sessions.
            pub fn cancel(self: *Owner) !void {
                const state = cast(self);
                try state.enter();
                defer state.busy = false;
                state.retire();
            }
            /// First-priority ingress only. Host forwards false to its existing editor.
            /// Preedit revokes snippet metadata and leaves IME to the native client.
            pub fn handleEvent(self: *Owner, window: z.Window, event: z.Event) !bool {
                const state = cast(self);
                try state.check();
                var scope = try state.adapter.beginNativeInput(window);
                defer scope.end();
                if (state.pin == null) return false;
                // Event ingress falls back explicitly after unrelated edits;
                // direct session operations still report StaleRevision.
                if (try state.document.composition() != null or try state.document.version() != state.revision) {
                    try self.cancel();
                    return false;
                }
                switch (event) {
                    .text_input => |input| {
                        _ = try self.edit(input.text);
                        return true;
                    },
                    .text_preedit, .cancel_input => {
                        try self.cancel();
                        return false;
                    },
                    .focus => |focused| if (!focused) {
                        try self.cancel();
                        return false;
                    },
                    .key_input => |key| if (!key.modifiers.control and !key.modifiers.alt and !key.modifiers.super) {
                        if (key.key == .tab) {
                            _ = try self.next(key.modifiers.shift);
                            return true;
                        }
                        if (key.key == .escape) {
                            try self.cancel();
                            return true;
                        }
                    },
                    else => {},
                }
                return false;
            }
            pub fn close(self: *Owner) !void {
                const state = cast(self);
                try state.check();
                if (state.clients != 0) return error.ClientsAlive;
                state.closing = true;
                state.retire();
                const allocator = state.allocator;
                const adapter = state.adapter;
                allocator.free(state.ranges[0]);
                allocator.free(state.ranges[1]);
                allocator.free(state.edits);
                allocator.free(state.selections);
                allocator.free(state.indices);
                if (state.transform_runtime) |*runtime| runtime.deinit() catch unreachable;
                allocator.free(state.transform_input);
                allocator.free(state.transform_results);
                allocator.destroy(state);
                adapter.releaseClient() catch unreachable;
            }
        };
        const State = struct {
            allocator: std.mem.Allocator,
            owner: std.Thread.Id,
            adapter: *Target,
            document: *d.Document,
            limits: Limits,
            ranges: [2][]Occurrence,
            edits: []d.Replacement,
            selections: []d.Selection,
            indices: []usize,
            transform_runtime: ?parser.transform.Runtime = null,
            transform_input: []u8 = &.{},
            transform_results: []u8 = &.{},
            owned: usize,
            front: u1 = 0,
            count: usize = 0,
            active_id: u16 = 0,
            primary_instance: usize = 0,
            revision: u64 = 0,
            pin: ?parser.Borrow = null,
            clients: usize = 0,
            busy: bool = false,
            closing: bool = false,
            fn check(self: *const State) !void {
                if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
                if (self.closing) return error.Closed;
                if (self.busy) return error.Busy;
            }
            fn enter(self: *State) !void {
                try self.check();
                self.busy = true;
            }
            fn current(self: *State) !void {
                if (self.pin == null) return error.NotActive;
                if (try self.document.composition() != null) return error.CompositionActive;
                if (try self.document.version() != self.revision) return error.StaleRevision;
            }
            fn validateTransforms(self: *const State, view: parser.View) !void {
                if (view.transforms.len == 0) return;
                for (view.occurrences) |item| if (item.transform_index) |index| {
                    const limits = self.limits.transforms orelse return error.TransformsRequired;
                    const program = &view.transforms[index].program;
                    if (program.code.len > limits.runtime.instructions or program.captures > limits.runtime.captures or item.range.end - item.range.start > limits.runtime.input_bytes) return error.CapacityExceeded;
                };
            }
            fn retire(self: *State) void {
                const pin = self.pin;
                self.pin = null;
                self.count = 0;
                if (pin) |value| value.end();
            }
            fn firstActive(self: *const State) Occurrence {
                for (self.ranges[self.front][0..self.count]) |item| if (item.live and item.id == self.active_id) return item;
                unreachable;
            }
            fn selectCandidate(self: *State, ranges: []const Occurrence, id: u16, primary_instance: usize, canonical: usize, relative: ?d.Selection) !struct { count: usize, primary: usize } {
                var count: usize = 0;
                var primary: usize = 0;
                var previous: ?d.Range = null;
                for (ranges) |item| if (item.live and item.id == id) {
                    const selection: d.Selection = if (relative) |value| blk: {
                        if (value.range().end > item.range.end - item.range.start) return error.InvalidSnippetSelection;
                        break :blk .{ .anchor = item.range.start + value.anchor, .caret = item.range.start + value.caret };
                    } else .{ .anchor = item.range.start, .caret = item.range.end };
                    const range = selection.range();
                    if (previous) |before| if (range.start <= before.start or range.start < before.end or (range.start == before.end and (range.start == range.end or before.start == before.end))) return error.AmbiguousTabstops;
                    previous = range;
                    self.selections[count] = selection;
                    if (item.instance == primary_instance and item.ordinal == canonical) primary = count;
                    count += 1;
                };
                if (count == 0) return error.InvalidSnippetSelection;
                return .{ .count = count, .primary = primary };
            }
            fn afterSelection(self: *State, changed: bool) !Outcome {
                const revision = try self.document.version();
                if ((changed and (self.revision == std.math.maxInt(u64) or revision != self.revision + 1)) or (!changed and revision != self.revision) or try self.document.composition() != null) {
                    self.retire();
                    return .{ .active = false, .revision = revision, .stale_after_commit = true };
                }
                self.revision = revision;
                return .{ .active = true, .revision = revision };
            }
            fn shift(value: usize, removed: usize, inserted: usize) !usize {
                return std.math.add(usize, std.math.sub(usize, value, removed) catch return error.CapacityExceeded, inserted) catch return error.CapacityExceeded;
            }
            fn isAncestor(ranges: []const Occurrence, parent: usize, child: usize, work: *usize) !bool {
                var ancestor_cursor = ranges[child].parent;
                while (ancestor_cursor) |index| {
                    if (work.* == 0) return error.WorkExceeded;
                    work.* -= 1;
                    if (index == parent) return true;
                    ancestor_cursor = ranges[index].parent;
                }
                return false;
            }
            fn navigate(self: *State, chosen: parser.Stop, leaving: bool) !Outcome {
                const old = self.ranges[self.front][0..self.count];
                const candidate = self.ranges[self.front ^ 1][0..self.count];
                var edits: usize = 0;
                var result_bytes: usize = 0;
                var available = self.limits.work;
                if (leaving and self.transform_runtime != null) {
                    if (old.len > available) return error.WorkExceeded;
                    available -= old.len;
                    for (old, 0..) |item, index| {
                        if (!item.live or item.id != self.active_id or item.transform_index == null) continue;
                        const limits = self.limits.transforms orelse return error.TransformsRequired;
                        const length = item.range.end - item.range.start;
                        if (length > self.transform_input.len) return error.CapacityExceeded;
                        if (length > available) return error.WorkExceeded;
                        available -= length;
                        const input = self.transform_input[0..length];
                        _ = try self.document.read(item.range, input);
                        var work: parser.transform.regex.Work = .{ .limit = available, .cancellation = if (limits.cancellation) |cancel| &cancel.requested else null };
                        const output = try self.transform_runtime.?.applyInto(&self.pin.?.data.transforms[item.transform_index.?], input, self.transform_results[result_bytes..], &work);
                        available -= work.used;
                        if (output.len > self.limits.replacement_bytes) return error.CapacityExceeded;
                        if (output.len > available) return error.WorkExceeded;
                        available -= output.len;
                        if (std.mem.indexOfScalar(u8, output, 0) != null) return error.EmbeddedNul;
                        const equal_bytes = @min(input.len, output.len);
                        if (equal_bytes > available) return error.WorkExceeded;
                        available -= equal_bytes;
                        if (!std.mem.eql(u8, input, output)) {
                            self.edits[edits] = .{ .range = item.range, .text = output };
                            self.indices[edits] = index;
                            edits += 1;
                        }
                        result_bytes += output.len;
                    }
                }
                var result: Outcome = undefined;
                if (self.transform_runtime != null) {
                    if (self.count > available) return error.WorkExceeded;
                    available -= self.count;
                }
                if (edits == 0) {
                    const selected = try self.selectCandidate(old, chosen.id, self.primary_instance, chosen.primary, null);
                    const changed = try self.adapter.setSelections(self.selections[0..selected.count], selected.primary);
                    result = try self.afterSelection(changed);
                } else {
                    if (self.count > available) return error.WorkExceeded;
                    available -= self.count;
                    @memcpy(candidate, old);
                    if (edits > available / self.count) return error.WorkExceeded;
                    available -= edits * self.count;
                    var remaining = edits;
                    while (remaining != 0) {
                        remaining -= 1;
                        const source = self.indices[remaining];
                        const edit = self.edits[remaining];
                        const removed = edit.range.end - edit.range.start;
                        for (candidate, 0..) |*item, index| {
                            if (!item.live) continue;
                            if (index == source or try isAncestor(old, index, source, &available)) {
                                item.range.end = try shift(item.range.end, removed, edit.text.len);
                            } else {
                                const original = old[index].range;
                                const follows = if (edit.range.start == edit.range.end)
                                    original.start > edit.range.end or (original.start == edit.range.end and index > source)
                                else
                                    original.start >= edit.range.end;
                                if (follows) {
                                    item.range.start = try shift(item.range.start, removed, edit.text.len);
                                    item.range.end = try shift(item.range.end, removed, edit.text.len);
                                }
                            }
                        }
                    }
                    const selected = try self.selectCandidate(candidate, chosen.id, self.primary_instance, chosen.primary, null);
                    const committed_revision = std.math.add(u64, self.revision, 1) catch return error.IdExhausted;
                    _ = try self.adapter.replaceManyWithSelections(self.revision, self.edits[0..edits], self.selections[0..selected.count], selected.primary);
                    const revision = try self.document.version();
                    if (revision != committed_revision or try self.document.composition() != null) {
                        self.retire();
                        return .{ .committed = true, .committed_revision = committed_revision, .active = false, .revision = revision, .stale_after_commit = true };
                    }
                    self.front ^= 1;
                    self.revision = revision;
                    result = .{ .committed = true, .committed_revision = committed_revision, .active = true, .revision = revision };
                }
                if (result.stale_after_commit) return result;
                self.active_id = chosen.id;
                if (chosen.id == 0) self.retire();
                result.active = chosen.id != 0;
                return result;
            }
            fn replace(self: *State, relative: d.Range, text: []const u8, selected: bool, whole: bool) !Outcome {
                if (text.len > self.limits.replacement_bytes) return error.CapacityExceeded;
                if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
                if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
                const old = self.ranges[self.front][0..self.count];
                const candidate = self.ranges[self.front ^ 1][0..self.count];
                @memcpy(candidate, old);
                var count: usize = 0;
                for (old, 0..) |item, at| if (item.live and item.id == self.active_id) {
                    const part: d.Range = if (whole) .{ .start = 0, .end = item.range.end - item.range.start } else relative;
                    if (part.start > part.end or part.end > item.range.end - item.range.start) return error.InvalidSnippetSelection;
                    self.indices[count] = at;
                    self.edits[count] = .{ .range = .{ .start = item.range.start + part.start, .end = item.range.start + part.end }, .text = text };
                    count += 1;
                };
                if (count > self.limits.work / self.count) return error.WorkExceeded;
                var work = self.limits.work - count * self.count;
                var remaining = count;
                while (remaining != 0) {
                    remaining -= 1;
                    const index = self.indices[remaining];
                    const edit = self.edits[remaining].range;
                    const removed = edit.end - edit.start;
                    for (candidate, 0..) |*item, at| {
                        if (!item.live) continue;
                        const ancestor = at == index or try isAncestor(old, at, index, &work);
                        if (ancestor) {
                            item.range.end = try shift(item.range.end, removed, text.len);
                            continue;
                        }
                        const descendant = try isAncestor(old, index, at, &work);
                        const range = old[at].range;
                        const touched = if (edit.start == edit.end)
                            (range.start < edit.start and edit.start < range.end)
                        else if (range.start == range.end)
                            (edit.start <= range.start and range.start < edit.end)
                        else
                            edit.start < range.end and range.start < edit.end;
                        if (descendant and ((edit.start == old[index].range.start and edit.end == old[index].range.end) or touched or (item.parent != null and !candidate[item.parent.?].live))) {
                            item.live = false;
                            continue;
                        }
                        // Empty insertions at a child's start sit before that
                        // child; its end boundary sits after it. Ancestors above
                        // were handled structurally, including empty parents.
                        const follows = if (edit.start == edit.end)
                            range.start > edit.end or (range.start == edit.end and at > index)
                        else
                            range.start >= edit.end;
                        if (follows) {
                            item.range.start = try shift(item.range.start, removed, text.len);
                            item.range.end = try shift(item.range.end, removed, text.len);
                        }
                    }
                }
                const caret = std.math.add(usize, if (whole) 0 else relative.start, text.len) catch return error.CapacityExceeded;
                const canonical = self.pin.?.data.stop(self.active_id).?.primary;
                const output = try self.selectCandidate(candidate, self.active_id, self.primary_instance, canonical, if (selected) null else .{ .anchor = caret, .caret = caret });
                const expected = self.revision;
                const committed_revision = std.math.add(u64, expected, 1) catch return error.IdExhausted;
                _ = try self.adapter.replaceManyWithSelections(expected, self.edits[0..count], self.selections[0..output.count], output.primary);
                const revision = try self.document.version();
                if (revision != committed_revision or try self.document.composition() != null) {
                    self.retire();
                    return .{ .committed = true, .committed_revision = committed_revision, .active = false, .revision = revision, .stale_after_commit = true };
                }
                self.front ^= 1;
                self.revision = revision;
                return .{ .committed = true, .committed_revision = committed_revision, .active = true, .revision = revision };
            }
        };
        fn cast(session: *Owner) *State {
            return @ptrCast(@alignCast(session));
        }
    }.Owner;
}

test {
    _ = parser;
}

fn expectText(document: *d.Document, expected: []const u8) !void {
    var bytes: [4096]u8 = undefined;
    const length = try document.byteLength();
    try std.testing.expectEqualStrings(expected, bytes[0..try document.read(.{ .start = 0, .end = length }, &bytes)]);
}
test "snippet mirrors choices navigation and exactly one text undo per operation" {
    const a = std.testing.allocator;
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "before", .{});
    defer document.close() catch unreachable;
    const session = try SessionFor(d.Document).create(a, document, .{});
    defer session.close() catch unreachable;
    const template = try Template.parse(a, "${1:猫}=$1;${2|red,green|};$0", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    const original = try document.selection();
    const revision = try document.version();
    const started = try session.start(template, revision, &.{.{ .start = 0, .end = 6 }}, 0);
    try std.testing.expect(started.committed and started.active and !started.stale_after_commit);
    try expectText(document, "猫=猫;red;");
    try std.testing.expectError(error.ClientsAlive, template.close());
    try std.testing.expectEqual(@as(usize, 2), try document.selectionCount());
    _ = try session.edit("a");
    try expectText(document, "a=a;red;");
    _ = try session.edit("b");
    try expectText(document, "ab=ab;red;");
    _ = try session.selectActive(.{ .anchor = 1, .caret = 0 });
    _ = try session.edit("😀");
    try expectText(document, "😀b=😀b;red;");
    _ = try session.next(false);
    try std.testing.expectEqual(@as(?u16, 2), (try session.status()).id);
    _ = try session.choose(1);
    try expectText(document, "😀b=😀b;green;");
    _ = try session.next(true);
    try std.testing.expectEqual(@as(?u16, 1), (try session.status()).id);
    _ = try session.next(false);
    try std.testing.expect(!(try session.next(false)).active);
    try std.testing.expect(try document.undo());
    try expectText(document, "😀b=😀b;red;");
    try std.testing.expect(try document.redo());
    try expectText(document, "😀b=😀b;green;");
    for (0..5) |_| try std.testing.expect(try document.undo());
    try expectText(document, "before");
    try std.testing.expectEqual(original, try document.selection());
}
test "snippet multicursor mirror ambiguity stale selection and composition are transactional" {
    const a = std.testing.allocator;
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "- -", .{});
    defer document.close() catch unreachable;
    const session = try SessionFor(d.Document).create(a, document, .{});
    defer session.close() catch unreachable;
    const template = try Template.parse(a, "${1:猫}:$1$0", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    _ = try session.start(template, try document.version(), &.{ .{ .start = 0, .end = 1 }, .{ .start = 2, .end = 3 } }, 1);
    try expectText(document, "猫:猫 猫:猫");
    try std.testing.expectEqual(@as(usize, 4), try document.selectionCount());
    const revision = try document.version();
    try std.testing.expectError(error.InvalidBoundary, session.selectActive(.{ .anchor = 1, .caret = 3 }));
    try std.testing.expectEqual(revision, try document.version());
    _ = try session.replaceActive("x");
    try expectText(document, "x:x x:x");
    _ = try document.setSelection(.{});
    try std.testing.expectError(error.StaleRevision, session.edit("z"));
    try std.testing.expect((try session.status()).active);
    try document.setComposition("a", .{});
    try std.testing.expectError(error.CompositionActive, session.edit("z"));
    try session.cancel();
    _ = try document.cancelComposition();
    const ambiguous = try Template.parse(a, "$1$1", .{});
    defer ambiguous.close() catch unreachable;
    const before = try document.version();
    try std.testing.expectError(error.AmbiguousTabstops, session.start(ambiguous, before, &.{.{ .start = 0, .end = 0 }}, 0));
    try std.testing.expectEqual(before, try document.version());
    try std.testing.expect(!(try session.status()).active);
}
fn sessionCandidate(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const session = try SessionFor(d.Document).create(allocator, document, .{});
    defer session.close() catch unreachable;
    const template = try Template.parse(allocator, "${1:猫}-$1$0", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    const before = try document.version();
    _ = session.start(template, before, &.{.{ .start = 0, .end = 3 }}, 0) catch |err| {
        try std.testing.expectEqual(before, try document.version());
        try expectText(document, "abc");
        try std.testing.expect(!(try session.status()).active);
        return err;
    };
    const revision = try document.version();
    _ = session.edit("😀") catch |err| {
        try std.testing.expectEqual(revision, try document.version());
        try expectText(document, "猫-猫");
        try std.testing.expect((try session.status()).active);
        return err;
    };
    try expectText(document, "😀-😀");
}
test "snippet complete session candidate OOM and budget failure preserve document and metadata" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sessionCandidate, .{});
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "", .{});
    defer document.close() catch unreachable;
    try std.testing.expectError(error.CapacityExceeded, SessionFor(d.Document).create(std.testing.allocator, document, .{ .bytes = 1 }));
}

fn completionCandidate(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc tail", .{});
    defer document.close() catch unreachable;
    const session = try SessionFor(d.Document).create(allocator, document, .{});
    defer session.close() catch unreachable;
    const template = try Template.parse(allocator, "${1:猫}=$1;$0", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    const revision = try document.version();
    const outcome = session.startCompletion(template, revision, &.{ .{ .range = .{ .start = 0, .end = 0 }, .text = "import;\n" }, .{ .range = .{ .start = 1, .end = 3 }, .text = "unused" }, .{ .range = .{ .start = 8, .end = 8 }, .text = "!" } }, 1) catch |err| {
        try std.testing.expectEqual(revision, try document.version());
        try expectText(document, "abc tail");
        try std.testing.expect(!(try session.status()).active);
        return err;
    };
    try std.testing.expect(outcome.committed and outcome.active);
    try expectText(document, "import;\na猫=猫; tail!");
    var selections: [4]d.Selection = undefined;
    const selected = try document.selections(&selections);
    try std.testing.expectEqualSlices(d.Selection, &.{ .{ .anchor = 9, .caret = 12 }, .{ .anchor = 13, .caret = 16 } }, selected.items);
    try session.cancel();
    try std.testing.expect(try document.undo());
    try expectText(document, "abc tail");
    try std.testing.expect(try document.redo());
    try expectText(document, "import;\na猫=猫; tail!");
}
test "completion template and literal additional edits share final selections and one OOM-safe undo" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, completionCandidate, .{});
}

test "snippet work budget capacity and wrong thread fail before document mutation" {
    const a = std.testing.allocator;
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc def", .{});
    defer document.close() catch unreachable;
    const template = try Template.parse(a, "${1:x}:$1$0", .{});
    defer template.close() catch unreachable;
    const session = try SessionFor(d.Document).create(a, document, .{ .work = 8 });
    defer session.close() catch unreachable;
    const revision = try document.version();
    try std.testing.expectError(error.OverlappingEdits, session.start(template, revision, &.{ .{ .start = 0, .end = 3 }, .{ .start = 2, .end = 4 } }, 0));
    _ = try session.start(template, revision, &.{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 7 } }, 0);
    const current = try document.version();
    // Four mirrors times six total occurrences exceed the eight work units.
    try std.testing.expectError(error.WorkExceeded, session.edit("a"));
    try std.testing.expectEqual(current, try document.version());
    try expectText(document, "x:x x:x");
    const Worker = struct {
        fn call(value: *SessionFor(d.Document), owned: *Template) void {
            std.testing.expectError(error.WrongThread, value.status()) catch unreachable;
            std.testing.expectError(error.WrongThread, value.cancel()) catch unreachable;
            std.testing.expectError(error.WrongThread, owned.view()) catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.call, .{ session, template });
    thread.join();
    try session.cancel();
}

test "nested child mirrors update ancestors and parent replacement retires only its descendants" {
    const doc = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "", .{});
    defer doc.close() catch unreachable;
    const session = try SessionFor(d.Document).create(std.testing.allocator, doc, .{});
    defer session.close() catch unreachable;
    const template = try Template.parse(std.testing.allocator, "${1:a${2:猫}} $1 $2$0", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    _ = try session.start(template, try doc.version(), &.{.{ .start = 0, .end = 0 }}, 0);
    _ = try session.next(false);
    try std.testing.expectEqual(@as(?u16, 2), (try session.status()).id);
    _ = try session.edit("😀");
    try expectText(doc, "a😀 a😀 😀");
    try std.testing.expectEqual(@as(usize, 3), try doc.selectionCount());
    _ = try session.next(true);
    _ = try session.edit("P");
    try expectText(doc, "P P 😀");
    try std.testing.expectEqual(@as(usize, 4), (try session.status()).occurrences);
    _ = try session.next(false);
    try std.testing.expectEqual(@as(usize, 1), try doc.selectionCount());
    _ = try session.replaceActive("z");
    try expectText(doc, "P P z");
    try session.cancel();
    try std.testing.expect(try doc.undo());
    try expectText(doc, "P P 😀");
    try std.testing.expect(try doc.undo());
    try expectText(doc, "a😀 a😀 😀");
    try std.testing.expect(try doc.undo());
    try expectText(doc, "a猫 a猫 猫");
    try std.testing.expect(try doc.undo());
    try expectText(doc, "");
}
test "nested partial parent insertion retains untouched descendants and navigation skips retired stops" {
    const doc = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "", .{});
    defer doc.close() catch unreachable;
    const session = try SessionFor(d.Document).create(std.testing.allocator, doc, .{});
    defer session.close() catch unreachable;
    const template = try Template.parse(std.testing.allocator, "${1:a${2:b}${3:}} $1$0", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    _ = try session.start(template, try doc.version(), &.{.{ .start = 0, .end = 0 }}, 0);
    _ = try session.selectActive(.{ .anchor = 0, .caret = 0 });
    _ = try session.edit("x");
    try expectText(doc, "xab xab");
    _ = try session.next(false);
    _ = try session.edit("B");
    try expectText(doc, "xaB xaB");
    _ = try session.next(true);
    _ = try session.replaceActive("p");
    try expectText(doc, "p p");
    try std.testing.expect(!(try session.next(false)).active);
}
fn nestedSessionCandidate(allocator: std.mem.Allocator) !void {
    const doc = try d.Document.create(allocator, std.Thread.getCurrentId(), "- -", .{});
    defer doc.close() catch unreachable;
    const session = try SessionFor(d.Document).create(allocator, doc, .{});
    defer session.close() catch unreachable;
    const template = try Template.parse(allocator, "${1:a${2:猫}} $1 $2$0", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    const revision = try doc.version();
    _ = session.start(template, revision, &.{ .{ .start = 0, .end = 1 }, .{ .start = 2, .end = 3 } }, 1) catch |err| {
        try std.testing.expectEqual(revision, try doc.version());
        try expectText(doc, "- -");
        return err;
    };
    _ = try session.next(false);
    const before = try doc.version();
    _ = session.edit("😀") catch |err| {
        try std.testing.expectEqual(before, try doc.version());
        try expectText(doc, "a猫 a猫 猫 a猫 a猫 猫");
        return err;
    };
    try expectText(doc, "a😀 a😀 😀 a😀 a😀 😀");
}
test "nested multi insertion and child edit allocation failure retain the old session" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, nestedSessionCandidate, .{});
}

test "nested empty boundary affinity and choice mirrors preserve the range forest" {
    const doc = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "", .{});
    defer doc.close() catch unreachable;
    const session = try SessionFor(d.Document).create(std.testing.allocator, doc, .{});
    defer session.close() catch unreachable;
    const template = try Template.parse(std.testing.allocator, "${1:${2:}x} $1$0", .{});
    defer template.close() catch unreachable;
    _ = try session.start(template, try doc.version(), &.{.{ .start = 0, .end = 0 }}, 0);
    _ = try session.selectActive(.{ .anchor = 0, .caret = 0 });
    _ = try session.edit("a");
    _ = try session.next(false);
    _ = try session.edit("Z");
    try expectText(doc, "aZx aZx");
    try session.cancel();
    const choices = try Template.parse(std.testing.allocator, "${1:a${2|b,c|}z} $1 $2$0", .{});
    defer choices.close() catch unreachable;
    _ = try session.start(choices, try doc.version(), &.{.{ .start = 0, .end = try doc.byteLength() }}, 0);
    _ = try session.next(false);
    _ = try session.choose(1);
    try expectText(doc, "acz acz c");
    _ = try session.next(true);
    _ = try session.selectActive(.{ .anchor = 1, .caret = 2 });
    _ = try session.edit("P");
    try expectText(doc, "aPz aPz c");
    _ = try session.next(false);
    try std.testing.expectEqual(@as(usize, 1), try doc.selectionCount());
    _ = try session.choose(0);
    try expectText(doc, "aPz aPz b");
    try session.cancel();
}
test "nested work refusal and preparation client gates leave the document unchanged" {
    const doc = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "", .{});
    defer doc.close() catch unreachable;
    const session = try SessionFor(d.Document).create(std.testing.allocator, doc, .{ .work = 20 });
    defer session.close() catch unreachable;
    try session.retainClient();
    try std.testing.expectError(error.ClientsAlive, session.close());
    try session.releaseClient();
    var preparation = try session.beginPreparation();
    try std.testing.expectError(error.Busy, session.close());
    try std.testing.expectError(error.Busy, session.cancel());
    preparation.end();
    preparation.end();
    const template = try Template.parse(std.testing.allocator, "${1:a${2:b}} $1 $2$0", .{});
    defer template.close() catch unreachable;
    _ = try session.start(template, try doc.version(), &.{.{ .start = 0, .end = 0 }}, 0);
    _ = try session.next(false);
    const revision = try doc.version();
    const selection = try doc.selection();
    try std.testing.expectError(error.WorkExceeded, session.edit("Z"));
    try expectText(doc, "ab ab b");
    try std.testing.expectEqual(revision, try doc.version());
    try std.testing.expectEqual(selection, try doc.selection());
    try std.testing.expectEqual(@as(?u16, 2), (try session.status()).id);
    try session.cancel();
}

test "zero-width sibling affinity uses immutable forest order at a shared byte offset" {
    const doc = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "", .{});
    defer doc.close() catch unreachable;
    const session = try SessionFor(d.Document).create(std.testing.allocator, doc, .{});
    defer session.close() catch unreachable;
    const template = try Template.parse(std.testing.allocator, "$0$2${1:}", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    _ = try session.start(template, try doc.version(), &.{.{ .start = 0, .end = 0 }}, 0);
    _ = try session.edit("X");
    _ = try session.next(false);
    try std.testing.expectEqual(@as(usize, 0), (try doc.selection()).caret);
    _ = try session.next(false);
    try std.testing.expectEqual(@as(usize, 0), (try doc.selection()).caret);
    try expectText(doc, "X");
}

test "leaving a tabstop transforms each own value and different-length mirrors replace atomically" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "", .{});
    defer doc.close() catch unreachable;
    const session = try SessionFor(d.Document).create(a, doc, .{ .transforms = .{} });
    defer session.close() catch unreachable;
    const template = try Template.parse(a, "${1:ab} ${1/(.*)/${1:/upcase}/} ${1/(.*)/<$1>/} ${2:next}$0", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    _ = try session.start(template, try doc.version(), &.{.{ .start = 0, .end = 0 }}, 0);
    try expectText(doc, "ab ab ab next");
    const before = try doc.version();
    const left = try session.next(false);
    try std.testing.expect(left.committed and left.active);
    try std.testing.expectEqual(before + 1, try doc.version());
    try expectText(doc, "ab AB <ab> next");
    _ = try session.next(true);
    var selections: [4]d.Selection = undefined;
    const selected = try doc.selections(&selections);
    try std.testing.expectEqualSlices(d.Selection, &.{ .{ .anchor = 0, .caret = 2 }, .{ .anchor = 3, .caret = 5 }, .{ .anchor = 6, .caret = 10 } }, selected.items);
    _ = try session.edit("z");
    try expectText(doc, "z z z next");
    try session.cancel();
    try std.testing.expect(try doc.undo());
    try expectText(doc, "ab AB <ab> next");
    try std.testing.expect(try doc.undo());
    try expectText(doc, "ab ab ab next");
    try std.testing.expect(try doc.undo());
    try expectText(doc, "");
}
test "nested leaf transforms shift ancestors across insertions and no-op transform adds no text undo" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "- -", .{});
    defer doc.close() catch unreachable;
    const session = try SessionFor(d.Document).create(a, doc, .{ .transforms = .{} });
    defer session.close() catch unreachable;
    const template = try Template.parse(a, "${1:p${2:ab} ${2/(.*)/<$1>/}} $1 ${3:x}$0", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    _ = try session.start(template, try doc.version(), &.{ .{ .start = 0, .end = 1 }, .{ .start = 2, .end = 3 } }, 1);
    _ = try session.next(false);
    _ = try session.next(false);
    try expectText(doc, "pab <ab> pab <ab> x pab <ab> pab <ab> x");
    _ = try session.next(true);
    _ = try session.replaceActive("猫");
    try expectText(doc, "p猫 猫 p猫 猫 x p猫 猫 p猫 猫 x");
    try session.cancel();
    const noop = try Template.parse(a, "${1:x}${1/(.*)/$0/}$0", .{});
    defer noop.close() catch unreachable;
    _ = try session.start(noop, try doc.version(), &.{.{ .start = 0, .end = try doc.byteLength() }}, 0);
    const outcome = try session.next(false);
    try std.testing.expect(!outcome.committed and !outcome.active);
    try std.testing.expect(try doc.undo());
    try expectText(doc, "p猫 猫 p猫 猫 x p猫 猫 p猫 猫 x");
}
fn transformedSessionCandidate(allocator: std.mem.Allocator) !void {
    const doc = try d.Document.create(allocator, std.Thread.getCurrentId(), "", .{});
    defer doc.close() catch unreachable;
    const session = try SessionFor(d.Document).create(allocator, doc, .{ .transforms = .{} });
    defer session.close() catch unreachable;
    const template = try Template.parse(allocator, "${1:ab} ${1/(.*)/<$1>/} ${2:x}$0", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    _ = try session.start(template, try doc.version(), &.{.{ .start = 0, .end = 0 }}, 0);
    const revision = try doc.version();
    const selection = try doc.selection();
    _ = session.next(false) catch |err| {
        try std.testing.expectEqual(revision, try doc.version());
        try std.testing.expectEqual(selection, try doc.selection());
        try std.testing.expectEqual(@as(?u16, 1), (try session.status()).id);
        try expectText(doc, "ab ab x");
        return err;
    };
    try expectText(doc, "ab <ab> x");
}
test "transform runtime opt-in aggregate capacity cancellation and all OOM retain old session" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, transformedSessionCandidate, .{});
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "", .{});
    defer doc.close() catch unreachable;
    const template = try Template.parse(a, "${1:ab} ${1/(.*)/<$1>/} ${1/(.*)/<$1>/} ${2:x}$0", .{});
    defer template.close() catch unreachable;
    const ordinary = try SessionFor(d.Document).create(a, doc, .{});
    defer ordinary.close() catch unreachable;
    try std.testing.expectError(error.TransformsRequired, ordinary.start(template, try doc.version(), &.{.{ .start = 0, .end = 0 }}, 0));
    var cancel: Cancellation = .{};
    const session = try SessionFor(d.Document).create(a, doc, .{ .transforms = .{ .results_bytes = 7, .cancellation = &cancel } });
    defer session.close() catch unreachable;
    _ = try session.start(template, try doc.version(), &.{.{ .start = 0, .end = 0 }}, 0);
    const revision = try doc.version();
    const selection = try doc.selection();
    try std.testing.expectError(error.OutputCapacityExceeded, session.next(false));
    try std.testing.expectEqual(revision, try doc.version());
    try std.testing.expectEqual(selection, try doc.selection());
    try std.testing.expectEqual(@as(?u16, 1), (try session.status()).id);
    cancel.request();
    try std.testing.expectError(error.Cancelled, session.next(false));
    try expectText(doc, "ab ab ab x");
    try session.cancel();
}
test "transformed empty Unicode mirrors and choice whole ranges preserve one history" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "", .{});
    defer doc.close() catch unreachable;
    const session = try SessionFor(d.Document).create(a, doc, .{ .transforms = .{} });
    defer session.close() catch unreachable;
    const template = try Template.parse(a, "${1|a,b|} ${1/(.*)//} ${1/(.*)/😀/} ${2:x}$0", .{});
    defer {
        session.cancel() catch unreachable;
        template.close() catch unreachable;
    }
    _ = try session.start(template, try doc.version(), &.{.{ .start = 0, .end = 0 }}, 0);
    _ = try session.next(false);
    try expectText(doc, "a  😀 x");
    _ = try session.next(true);
    _ = try session.choose(1);
    try expectText(doc, "b b b x");
    try std.testing.expect(try doc.undo());
    try expectText(doc, "a  😀 x");
    try std.testing.expectError(error.StaleRevision, session.next(false));
    try session.cancel();
    try std.testing.expect(try doc.undo());
    try expectText(doc, "a a a x");
}
test "transform work and nonASCII case failures preserve active ranges and selection" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "", .{});
    defer doc.close() catch unreachable;
    const template = try Template.parse(a, "${1:猫} ${1/(.*)/${1:/upcase}/} ${2:x}$0", .{});
    defer template.close() catch unreachable;
    for ([_]usize{ 16, 1024 * 1024 }) |work| {
        const session = try SessionFor(d.Document).create(a, doc, .{ .transforms = .{}, .work = work });
        defer session.close() catch unreachable;
        _ = try session.start(template, try doc.version(), &.{.{ .start = 0, .end = try doc.byteLength() }}, 0);
        const revision = try doc.version();
        const selection = try doc.selection();
        try std.testing.expectError(if (work == 16) error.WorkExceeded else error.UnsupportedCaseMapping, session.next(false));
        try std.testing.expectEqual(revision, try doc.version());
        try std.testing.expectEqual(selection, try doc.selection());
        try std.testing.expectEqual(@as(?u16, 1), (try session.status()).id);
        try expectText(doc, "猫 猫 x");
        try session.cancel();
    }
}
