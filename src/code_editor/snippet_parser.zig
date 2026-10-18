const std = @import("std");
pub const transform = @import("snippet_transform.zig");

pub const Limits = struct {
    source_bytes: usize = 65536,
    output_bytes: usize = 1024 * 1024,
    occurrences: usize = 512,
    stops: usize = 128,
    choices: usize = 256,
    nodes: usize = 4096,
    depth: usize = 16,
    variables: usize = 128,
    variable_bytes: usize = 65536,
    transforms: usize = 128,
    transform_limits: transform.Limits = .{},
    bytes: usize = 4 * 1024 * 1024,
    work: usize = 4 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.transforms > 1024 or self.nodes == 0 or self.nodes > 65536 or self.depth == 0 or self.depth > 64 or self.variables > 1024 or self.variable_bytes > 16 * 1024 * 1024 or self.source_bytes == 0 or self.source_bytes > 1024 * 1024 or self.output_bytes > 16 * 1024 * 1024 or self.occurrences == 0 or self.occurrences > 4096 or self.stops == 0 or self.stops > 1024 or self.choices > 4096 or self.bytes < @sizeOf(State) or self.bytes > 64 * 1024 * 1024 or self.work == 0 or self.work > 128 * 1024 * 1024) return error.InvalidLimits;
    }
};
/// Cooperative cancellation of explicit preparation. No thread is created.
pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pub fn request(self: *Cancellation) void {
        self.requested.store(true, .release);
    }
    fn check(self: *const Cancellation) !void {
        if (self.requested.load(.acquire)) return error.Cancelled;
    }
};
pub const Resolution = enum { value, unset, unsupported };
/// Callback-only sink. Writes copy literal bytes and never allocate. Neither
/// the sink nor its backing storage may escape the resolver call.
pub const ValueWriter = struct {
    buffer: []u8,
    len: usize = 0,
    work: *usize,
    work_limit: usize,
    cancellation: ?*const Cancellation,
    pub fn writeAll(self: *ValueWriter, bytes: []const u8) !void {
        if (self.cancellation) |cancel| try cancel.check();
        if (bytes.len > self.buffer.len - self.len) return error.VariableCapacityExceeded;
        if (bytes.len > self.work_limit - self.work.*) return error.WorkExceeded;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.work.* += bytes.len;
    }
};
pub const Resolver = struct {
    context: *anyopaque,
    resolve: *const fn (*anyopaque, []const u8, *ValueWriter) anyerror!Resolution,
};
pub const ParseOptions = struct { resolver: ?Resolver = null, cancellation: ?*const Cancellation = null, transform_runtime: transform.RuntimeLimits = .{} };
pub const Range = struct { start: usize, end: usize };
pub const Stop = struct { id: u16, value: Range, choices: Range = .{ .start = 0, .end = 0 }, defined: bool = false, primary: usize = 0 };
pub const Occurrence = struct { id: u16, range: Range, parent: ?usize = null, transform_index: ?usize = null };
pub const View = struct {
    text: []const u8,
    stops: []const Stop,
    occurrences: []const Occurrence,
    values: []const u8,
    choices: []const Range,
    transforms: []const transform.Transform,
    pub fn stop(self: View, id: u16) ?Stop {
        for (self.stops) |item| if (item.id == id) return item;
        return null;
    }
    pub fn choice(self: View, id: u16, index: usize) ![]const u8 {
        const item = self.stop(id) orelse return error.UnknownTabstop;
        if (index >= item.choices.end - item.choices.start) return error.InvalidChoice;
        const range = self.choices[item.choices.start + index];
        return self.values[range.start..range.end];
    }
};
pub const Stats = struct { owned_bytes: usize, peak_bytes: usize, work: usize };
pub const Borrow = struct {
    template: *Template,
    data: View,
    pub fn end(self: Borrow) void {
        const state = cast(self.template);
        std.debug.assert(state.owner == std.Thread.getCurrentId() and state.clients != 0);
        state.clients -= 1;
    }
};
/// Immutable owning parse result. Pointer copies are borrows; a Borrow pins
/// its storage through allocator reentry and must end exactly once.
pub const Template = opaque {
    pub fn parse(allocator: std.mem.Allocator, source: []const u8, limits: Limits) !*Template {
        return parseResolved(allocator, source, limits, .{});
    }
    pub fn parseResolved(allocator: std.mem.Allocator, source: []const u8, limits: Limits, options: ParseOptions) !*Template {
        try limits.validate();
        if (options.cancellation) |cancel| try cancel.check();
        if (source.len > limits.source_bytes) return error.SourceCapacityExceeded;
        if (source.len * 2 > limits.work) return error.WorkExceeded;
        if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, source, 0) != null) return error.EmbeddedNul;
        var budget: Budget = .{ .child = allocator, .limit = limits.bytes };
        var builder: Builder = .{ .allocator = budget.allocator(), .limits = limits, .options = options, .work = source.len * 2 };
        var builder_live = true;
        defer if (builder_live) builder.deinit();
        const input = builder.allocator.dupe(u8, source) catch |err| return if (err == error.OutOfMemory and budget.denied) error.CapacityExceeded else err;
        var input_live = true;
        defer if (input_live) builder.allocator.free(input);
        const result = builder.build(input, allocator, &budget) catch |err| return if (err == error.OutOfMemory and budget.denied) error.CapacityExceeded else err;
        errdefer result.close() catch unreachable;
        input_live = false;
        builder.allocator.free(input);
        builder_live = false;
        builder.deinit();
        if (options.cancellation) |cancel| try cancel.check();
        return result;
    }
    pub fn view(self: *const Template) !View {
        const state = cast(@constCast(self));
        try state.check();
        return state.view();
    }
    pub fn borrow(self: *Template) !Borrow {
        const state = cast(self);
        try state.check();
        state.clients = std.math.add(usize, state.clients, 1) catch return error.CapacityExceeded;
        return .{ .template = self, .data = state.view() };
    }
    pub fn stats(self: *const Template) !Stats {
        const state = cast(@constCast(self));
        try state.check();
        return state.stats;
    }
    pub fn close(self: *Template) !void {
        const state = cast(self);
        try state.check();
        if (state.clients != 0) return error.ClientsAlive;
        state.closing = true;
        const allocator = state.allocator;
        allocator.free(state.text);
        allocator.free(state.values);
        allocator.free(state.stops);
        allocator.free(state.occurrences);
        allocator.free(state.choices);
        for (state.transforms) |*item| item.deinit() catch unreachable;
        allocator.free(state.transforms);
        allocator.destroy(state);
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    text: []u8,
    values: []u8,
    stops: []Stop,
    occurrences: []Occurrence,
    choices: []Range,
    transforms: []transform.Transform,
    stats: Stats,
    clients: usize = 0,
    closing: bool = false,
    fn check(self: *const State) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closing) return error.Closed;
    }
    fn view(self: *const State) View {
        return .{ .text = self.text, .values = self.values, .stops = self.stops, .occurrences = self.occurrences, .choices = self.choices, .transforms = self.transforms };
    }
};
fn cast(template: *Template) *State {
    return @ptrCast(@alignCast(template));
}
const Node = struct {
    kind: enum { literal, stop, variable },
    value: Range = .{ .start = 0, .end = 0 },
    id: u16 = 0,
    child: ?usize = null,
    next: ?usize = null,
    definition: bool = false,
    choices: Range = .{ .start = 0, .end = 0 },
    variable: usize = 0,
    transform_index: ?usize = null,
    transformed_value: ?Range = null,
};
const Definition = struct { info: Stop, node: ?usize = null, visiting: bool = false, canonical: bool = false };
const Variable = struct { name: Range, resolution: ?Resolution = null, value: Range = .{ .start = 0, .end = 0 } };
const Builder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    options: ParseOptions,
    input: []const u8 = &.{},
    values: std.ArrayList(u8) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    stops: std.ArrayList(Definition) = .empty,
    choices: std.ArrayList(Range) = .empty,
    variables: std.ArrayList(Variable) = .empty,
    variable_buffer: ?[]u8 = null,
    variable_used: usize = 0,
    output: std.ArrayList(u8) = .empty,
    expanded: std.ArrayList(Occurrence) = .empty,
    transforms: std.ArrayList(transform.Transform) = .empty,
    transform_runtime: ?transform.Runtime = null,
    transform_output: ?[]u8 = null,
    work: usize = 0,
    source_occurrences: usize = 0,
    final: bool = false,
    fn charge(self: *Builder, amount: usize) !void {
        if (self.options.cancellation) |cancel| try cancel.check();
        if (amount > self.limits.work -| self.work) return error.WorkExceeded;
        self.work += amount;
    }
    fn deinit(self: *Builder) void {
        self.values.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.stops.deinit(self.allocator);
        self.choices.deinit(self.allocator);
        self.variables.deinit(self.allocator);
        if (self.variable_buffer) |buffer| self.allocator.free(buffer);
        self.output.deinit(self.allocator);
        self.expanded.deinit(self.allocator);
        for (self.transforms.items) |*item| item.deinit() catch unreachable;
        self.transforms.deinit(self.allocator);
        if (self.transform_runtime) |*runtime| runtime.deinit() catch unreachable;
        if (self.transform_output) |output| self.allocator.free(output);
    }
    fn add(self: *Builder, node: Node) !usize {
        try self.charge(1);
        if (self.nodes.items.len == self.limits.nodes) return error.NodesFull;
        try self.nodes.append(self.allocator, node);
        return self.nodes.items.len - 1;
    }
    fn find(self: *Builder, id: u16) !usize {
        try self.charge(self.stops.items.len);
        for (self.stops.items, 0..) |item, at| if (item.info.id == id) return at;
        if (self.stops.items.len == self.limits.stops) return error.StopsFull;
        try self.stops.append(self.allocator, .{ .info = .{ .id = id, .value = .{ .start = 0, .end = 0 }, .primary = std.math.maxInt(usize) } });
        return self.stops.items.len - 1;
    }
    fn link(self: *Builder, first: *?usize, last: *?usize, index: usize) void {
        if (last.*) |previous| self.nodes.items[previous].next = index else first.* = index;
        last.* = index;
    }
    fn literal(self: *Builder, at: *usize, choice: bool) !Range {
        const begin = self.values.items.len;
        while (at.* < self.input.len) {
            try self.charge(1);
            const byte = self.input[at.*];
            if (byte == '}' or (choice and (byte == ',' or byte == '|')) or (!choice and byte == '$')) break;
            if (byte == '$') return error.UnsupportedNestedPlaceholder;
            if (byte == '\\') {
                at.* += 1;
                if (at.* == self.input.len) return error.InvalidEscape;
                const escaped = self.input[at.*];
                if (escaped != '\\' and escaped != '$' and escaped != '}' and !(choice and (escaped == ',' or escaped == '|'))) return error.InvalidEscape;
                try self.charge(1);
            }
            try self.values.append(self.allocator, self.input[at.*]);
            at.* += 1;
        }
        return .{ .start = begin, .end = self.values.items.len };
    }
    fn compileTransform(self: *Builder, at: *usize) !usize {
        if (self.transforms.items.len == self.limits.transforms) return error.TransformsFull;
        at.* += 1;
        const pattern_begin = at.*;
        while (at.* < self.input.len and self.input[at.*] != '/') {
            try self.charge(1);
            if (self.input[at.*] == '\\') {
                at.* += 1;
                if (at.* == self.input.len) return error.UnclosedTransform;
            }
            at.* += 1;
        }
        if (at.* == self.input.len) return error.UnclosedTransform;
        const pattern = self.input[pattern_begin..at.*];
        at.* += 1;
        const format_begin = at.*;
        var depth: usize = 0;
        while (at.* < self.input.len) {
            try self.charge(1);
            const byte = self.input[at.*];
            if (byte == '\\') {
                at.* += 1;
                if (at.* == self.input.len) return error.UnclosedTransform;
            } else if (byte == '$' and at.* + 1 < self.input.len and self.input[at.* + 1] == '{') {
                if (depth == self.limits.depth) return error.DepthExceeded;
                depth += 1;
                at.* += 1;
            } else if (byte == '}' and depth != 0) {
                depth -= 1;
            } else if (byte == '/' and depth == 0) break;
            at.* += 1;
        }
        if (at.* == self.input.len) return error.UnclosedTransform;
        const format = self.input[format_begin..at.*];
        at.* += 1;
        const flags_begin = at.*;
        while (at.* < self.input.len and self.input[at.*] != '}') : (at.* += 1) try self.charge(1);
        if (at.* == self.input.len) return error.UnclosedTransform;
        var limits = self.limits.transform_limits;
        limits.cancellation = if (self.options.cancellation) |cancel| &cancel.requested else null;
        if (self.work == self.limits.work) return error.WorkExceeded;
        limits.work = @min(limits.work, self.limits.work - self.work);
        var compiled = try transform.Transform.compile(self.allocator, pattern, format, self.input[flags_begin..at.*], limits);
        errdefer compiled.deinit() catch unreachable;
        try self.charge(compiled.compile_work);
        try self.transforms.append(self.allocator, compiled);
        return self.transforms.items.len - 1;
    }
    // Recursion is limited before entering each frame; source and expanded
    // dependency depth share the same hard maximum of 64.
    fn sequence(self: *Builder, at: *usize, depth: usize) anyerror!?usize {
        if (depth > self.limits.depth) return error.DepthExceeded;
        var first: ?usize = null;
        var last: ?usize = null;
        while (at.* < self.input.len and !(depth != 0 and self.input[at.*] == '}')) {
            if (self.input[at.*] != '$') {
                // A root '}' is ordinary literal text.
                const value = if (self.input[at.*] == '}') blk: {
                    const begin = self.values.items.len;
                    try self.charge(1);
                    try self.values.append(self.allocator, '}');
                    at.* += 1;
                    break :blk Range{ .start = begin, .end = begin + 1 };
                } else try self.literal(at, false);
                if (value.start != value.end) self.link(&first, &last, try self.add(.{ .kind = .literal, .value = value }));
                continue;
            }
            try self.charge(1);
            at.* += 1;
            if (at.* == self.input.len) return error.InvalidSyntax;
            const braced = self.input[at.*] == '{';
            if (braced) at.* += 1;
            if (at.* == self.input.len) return error.UnclosedPlaceholder;
            var node: Node = undefined;
            if (std.ascii.isDigit(self.input[at.*])) {
                var id: u32 = 0;
                while (at.* < self.input.len and std.ascii.isDigit(self.input[at.*])) : (at.* += 1) {
                    try self.charge(1);
                    id = std.math.mul(u32, id, 10) catch return error.InvalidTabstop;
                    id = std.math.add(u32, id, self.input[at.*] - '0') catch return error.InvalidTabstop;
                    if (id > 65535) return error.InvalidTabstop;
                }
                if (id == 0 and depth != 0) return error.UnsupportedNestedFinalStop;
                node = .{ .kind = .stop, .id = @intCast(id) };
            } else {
                const begin = at.*;
                if (!std.ascii.isAlphabetic(self.input[at.*]) and self.input[at.*] != '_') return error.InvalidSyntax;
                while (at.* < self.input.len and (std.ascii.isAlphanumeric(self.input[at.*]) or self.input[at.*] == '_')) : (at.* += 1) try self.charge(1);
                node = .{ .kind = .variable, .value = .{ .start = begin, .end = at.* } };
            }
            if (braced) {
                if (at.* == self.input.len) return error.UnclosedPlaceholder;
                if (self.input[at.*] == '/') {
                    if (node.kind == .stop and node.id == 0) return error.UnsupportedFinalTransform;
                    node.transform_index = try self.compileTransform(at);
                } else if (self.input[at.*] == ':') {
                    at.* += 1;
                    node.definition = true;
                    node.child = try self.sequence(at, depth + 1);
                } else if (self.input[at.*] == '|' and node.kind == .stop) {
                    node.definition = true;
                    at.* += 1;
                    const begin = self.choices.items.len;
                    while (true) {
                        if (self.choices.items.len == self.limits.choices) return error.ChoicesFull;
                        try self.choices.append(self.allocator, try self.literal(at, true));
                        if (at.* == self.input.len or self.input[at.*] == '}') return error.InvalidChoice;
                        const done = self.input[at.*] == '|';
                        at.* += 1;
                        if (done) break;
                    }
                    node.choices = .{ .start = begin, .end = self.choices.items.len };
                }
                if (at.* == self.input.len) return error.UnclosedPlaceholder;
                if (self.input[at.*] != '}') return error.InvalidSyntax;
                at.* += 1;
            }
            self.link(&first, &last, try self.add(node));
        }
        return first;
    }
    fn variable(self: *Builder, name: Range) !usize {
        for (self.variables.items, 0..) |item, i| {
            try self.charge(name.end - name.start);
            if (std.mem.eql(u8, self.input[name.start..name.end], self.input[item.name.start..item.name.end])) return i;
        }
        if (self.variables.items.len == self.limits.variables) return error.VariablesFull;
        const resolver = self.options.resolver orelse return error.UnsupportedVariable;
        if (self.variable_buffer == null) self.variable_buffer = try self.allocator.alloc(u8, self.limits.variable_bytes);
        try self.charge(1);
        var writer: ValueWriter = .{ .buffer = self.variable_buffer.?[self.variable_used..], .work = &self.work, .work_limit = self.limits.work, .cancellation = self.options.cancellation };
        const resolution = try resolver.resolve(resolver.context, self.input[name.start..name.end], &writer);
        try self.charge(1);
        if (resolution == .unsupported) return error.UnsupportedVariable;
        if (resolution != .value and writer.len != 0) return error.InvalidVariableResolution;
        try self.charge(writer.len * 2);
        const bytes = writer.buffer[0..writer.len];
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.EmbeddedNul;
        const begin = self.variable_used;
        self.variable_used += writer.len;
        try self.variables.append(self.allocator, .{ .name = name, .resolution = resolution, .value = .{ .start = begin, .end = self.variable_used } });
        return self.variables.items.len - 1;
    }
    fn collect(self: *Builder, first: ?usize, depth: usize) anyerror!void {
        if (first == null) return;
        if (depth > self.limits.depth) return error.DepthExceeded;
        var current = first;
        while (current) |i| {
            try self.charge(1);
            const node = self.nodes.items[i];
            switch (node.kind) {
                .literal => {},
                .variable => {
                    const index = try self.variable(node.value);
                    self.nodes.items[i].variable = index;
                    if (self.variables.items[index].resolution.? == .unset) try self.collect(node.child, depth + 1);
                },
                .stop => {
                    if (self.source_occurrences == self.limits.occurrences) return error.OccurrencesFull;
                    self.source_occurrences += 1;
                    if (node.id == 0) {
                        if (self.final) return error.DuplicateFinalStop;
                        self.final = true;
                    }
                    const index = try self.find(node.id);
                    if (node.definition) {
                        if (self.stops.items[index].node != null) return error.DuplicateDefinition;
                        self.stops.items[index].node = i;
                        self.stops.items[index].info.defined = true;
                        self.stops.items[index].info.choices = node.choices;
                    }
                    try self.collect(node.child, depth + 1);
                },
            }
            current = node.next;
        }
    }
    fn emit(self: *Builder, bytes: []const u8) !void {
        if (bytes.len > self.limits.output_bytes -| self.output.items.len) return error.OutputCapacityExceeded;
        try self.charge(bytes.len);
        try self.output.appendSlice(self.allocator, bytes);
    }
    fn variableTransform(self: *Builder, index: usize) !Range {
        if (self.nodes.items[index].transformed_value) |value| return value;
        if (self.transform_runtime == null) {
            self.transform_runtime = try transform.Runtime.init(self.allocator, self.options.transform_runtime);
            self.transform_output = try self.allocator.alloc(u8, self.options.transform_runtime.result_bytes);
        }
        const node = self.nodes.items[index];
        const variable_entry = self.variables.items[node.variable];
        const input: []const u8 = if (variable_entry.resolution.? == .value) self.variable_buffer.?[variable_entry.value.start..variable_entry.value.end] else "";
        var work: transform.regex.Work = .{ .limit = self.limits.work, .used = self.work, .cancellation = if (self.options.cancellation) |cancel| &cancel.requested else null };
        defer self.work = work.used;
        const value = try self.transform_runtime.?.applyInto(&self.transforms.items[node.transform_index.?], input, self.transform_output.?, &work);
        try work.charge(value.len);
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.EmbeddedNul;
        const begin = self.values.items.len;
        try self.values.appendSlice(self.allocator, value);
        const range: Range = .{ .start = begin, .end = self.values.items.len };
        self.nodes.items[index].transformed_value = range;
        return range;
    }
    fn expand(self: *Builder, first: ?usize, parent: ?usize, depth: usize, canonical_path: bool) anyerror!void {
        if (first == null) return;
        if (depth > self.limits.depth) return error.DepthExceeded;
        var current = first;
        while (current) |i| {
            try self.charge(1);
            const node = self.nodes.items[i];
            switch (node.kind) {
                .literal => try self.emit(self.values.items[node.value.start..node.value.end]),
                .variable => {
                    const entry = self.variables.items[node.variable];
                    if (node.transform_index != null) {
                        const value = try self.variableTransform(i);
                        try self.emit(self.values.items[value.start..value.end]);
                    } else if (entry.resolution.? == .value) try self.emit(self.variable_buffer.?[entry.value.start..entry.value.end]) else try self.expand(node.child, parent, depth + 1, canonical_path);
                },
                .stop => {
                    const index = try self.find(node.id);
                    if (self.stops.items[index].visiting) return error.CyclicPlaceholder;
                    if (self.expanded.items.len == self.limits.occurrences) return error.OccurrencesFull;
                    const ordinal = self.expanded.items.len;
                    try self.expanded.append(self.allocator, .{ .id = node.id, .parent = parent, .transform_index = node.transform_index, .range = .{ .start = self.output.items.len, .end = 0 } });
                    const definition = self.stops.items[index].node;
                    const canonical = canonical_path and (definition == null or definition.? == i);
                    if (self.stops.items[index].info.primary == std.math.maxInt(usize) or (canonical and !self.stops.items[index].canonical)) {
                        self.stops.items[index].info.primary = ordinal;
                        self.stops.items[index].canonical = canonical;
                    }
                    self.stops.items[index].visiting = true;
                    if (definition) |def| {
                        const body = self.nodes.items[def];
                        if (body.choices.start != body.choices.end) {
                            const value = self.choices.items[body.choices.start];
                            try self.emit(self.values.items[value.start..value.end]);
                        } else try self.expand(body.child, ordinal, depth + 1, canonical);
                    }
                    self.stops.items[index].visiting = false;
                    self.expanded.items[ordinal].range.end = self.output.items.len;
                },
            }
            current = node.next;
        }
    }
    fn build(self: *Builder, input: []const u8, child: std.mem.Allocator, budget: *Budget) !*Template {
        self.input = input;
        var at: usize = 0;
        const root = try self.sequence(&at, 0);
        try self.collect(root, 0);
        try self.expand(root, null, 0, true);
        // The logical source must be a leaf. Every reference expands the same
        // definition forest, so a first direct child proves that boundary.
        for (self.expanded.items, 0..) |item, index| {
            try self.charge(1);
            if (item.transform_index != null and index + 1 < self.expanded.items.len and self.expanded.items[index + 1].parent == index) return error.UnsupportedTransformSource;
        }
        if (!self.final) {
            if (self.expanded.items.len == self.limits.occurrences) return error.OccurrencesFull;
            const index = try self.find(0);
            self.stops.items[index].info.primary = self.expanded.items.len;
            try self.expanded.append(self.allocator, .{ .id = 0, .range = .{ .start = self.output.items.len, .end = self.output.items.len } });
        }
        const stops = try self.allocator.alloc(Stop, self.stops.items.len);
        errdefer self.allocator.free(stops);
        for (self.stops.items, stops) |item, *stop| {
            stop.* = item.info;
            const range = self.expanded.items[stop.primary].range;
            try self.charge(range.end - range.start);
            const begin = self.values.items.len;
            try self.values.appendSlice(self.allocator, self.output.items[range.start..range.end]);
            stop.value = .{ .start = begin, .end = self.values.items.len };
        }
        const sort_steps = if (stops.len < 2) 0 else std.math.log2_int_ceil(usize, stops.len);
        try self.charge(stops.len * sort_steps);
        std.mem.sort(Stop, stops, {}, struct {
            fn less(_: void, a: Stop, b: Stop) bool {
                return (if (a.id == 0) @as(u32, 65536) else a.id) < (if (b.id == 0) @as(u32, 65536) else b.id);
            }
        }.less);
        const state = try self.allocator.create(State);
        errdefer self.allocator.destroy(state);
        const output = try self.output.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(output);
        const occurrences = try self.expanded.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(occurrences);
        const values = try self.values.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(values);
        const choices = try self.choices.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(choices);
        const transforms = try self.transforms.toOwnedSlice(self.allocator);
        errdefer {
            for (transforms) |*item| item.deinit() catch unreachable;
            self.allocator.free(transforms);
        }
        try self.charge(0);
        var owned = @sizeOf(State) + output.len + values.len + stops.len * @sizeOf(Stop) + occurrences.len * @sizeOf(Occurrence) + choices.len * @sizeOf(Range);
        for (transforms) |*item| {
            owned += item.owned_bytes;
            item.program.allocator = child;
            item.format.allocator = child;
        }
        state.* = .{ .allocator = child, .owner = std.Thread.getCurrentId(), .text = output, .values = values, .stops = stops, .occurrences = occurrences, .choices = choices, .transforms = transforms, .stats = .{ .owned_bytes = owned, .peak_bytes = budget.peak, .work = self.work } };
        return @ptrCast(state);
    }
};
const Budget = struct {
    child: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    denied: bool = false,
    fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(context));
        if (bytes > self.limit -| self.live) {
            self.denied = true;
            return null;
        }
        const result = self.child.rawAlloc(bytes, alignment, ret) orelse return null;
        self.live += bytes;
        self.peak = @max(self.peak, self.live);
        return result;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(context));
        self.child.rawFree(bytes, alignment, ret);
        self.live -= bytes.len;
    }
};

test "snippet owning parser resolves forward mirrors choices escapes and final stop" {
    const template = try Template.parse(std.testing.allocator, "$2 ${1:hello} ${2|red,green\\,blue,|} $1 \\$x", .{});
    defer template.close() catch unreachable;
    const view = try template.view();
    try std.testing.expectEqualStrings("red hello red hello $x", view.text);
    try std.testing.expectEqual(@as(u16, 1), view.stops[0].id);
    try std.testing.expectEqual(@as(u16, 0), view.stops[2].id);
    try std.testing.expectEqualStrings("green,blue", try view.choice(2, 1));
    const peak = (try template.stats()).peak_bytes;
    try std.testing.expectError(error.CapacityExceeded, Template.parse(std.testing.allocator, "$2 ${1:hello} ${2|red,green\\,blue,|} $1 \\$x", .{ .bytes = peak - 1 }));
    const pin = try template.borrow();
    try std.testing.expectError(error.ClientsAlive, template.close());
    pin.end();
}
fn candidate(allocator: std.mem.Allocator) !void {
    const template = try Template.parse(allocator, "fn ${1:name}(${2|a,b|}) {$1;$0}", .{});
    defer template.close() catch unreachable;
}
test "snippet syntax capability and all allocation failures are explicit" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, candidate, .{});
    const cases = .{ .{ "$NAME", error.UnsupportedVariable }, .{ "${1/(a?)*/b/}", error.UnsupportedNullableRepeat }, .{ "${1:a}${1:b}", error.DuplicateDefinition }, .{ "$0$0", error.DuplicateFinalStop }, .{ "${1", error.UnclosedPlaceholder }, .{ "\\q", error.InvalidEscape } };
    inline for (cases) |item| try std.testing.expectError(item[1], Template.parse(std.testing.allocator, item[0], .{}));
    try std.testing.expectError(error.OutputCapacityExceeded, Template.parse(std.testing.allocator, "${1:ab}$1", .{ .output_bytes = 3 }));
    try std.testing.expectError(error.WorkExceeded, Template.parse(std.testing.allocator, "abc", .{ .work = 1 }));
    try std.testing.expectError(error.StopsFull, Template.parse(std.testing.allocator, "$1$2", .{ .stops = 1 }));
    try std.testing.expectError(error.OccurrencesFull, Template.parse(std.testing.allocator, "$1$1", .{ .occurrences = 1 }));
    try std.testing.expectError(error.ChoicesFull, Template.parse(std.testing.allocator, "${1|a,b|}", .{ .choices = 1 }));
}

const TestResolver = struct {
    calls: usize = 0,
    resolution: Resolution = .value,
    text: []const u8 = "$1",
    cancellation: ?*Cancellation = null,
    fn resolve(ptr: *anyopaque, _: []const u8, writer: *ValueWriter) !Resolution {
        const self: *TestResolver = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.cancellation) |cancel| cancel.request();
        if (self.resolution == .value) try writer.writeAll(self.text);
        return self.resolution;
    }
    fn callback(self: *TestResolver) Resolver {
        return .{ .context = self, .resolve = resolve };
    }
};
test "nested templates expand complete mirror forests with stable canonical parents" {
    const template = try Template.parse(std.testing.allocator, "${1:a${2:猫}} $1 $2", .{});
    defer template.close() catch unreachable;
    const view = try template.view();
    try std.testing.expectEqualStrings("a猫 a猫 猫", view.text);
    try std.testing.expectEqual(@as(usize, 6), view.occurrences.len);
    try std.testing.expectEqual(@as(?usize, 0), view.occurrences[1].parent);
    try std.testing.expectEqual(@as(?usize, 2), view.occurrences[3].parent);
    try std.testing.expectEqual(@as(?usize, null), view.occurrences[4].parent);
    try std.testing.expectEqual(@as(usize, 1), view.stop(2).?.primary);
    try std.testing.expectError(error.CyclicPlaceholder, Template.parse(std.testing.allocator, "${1:$1}", .{}));
    try std.testing.expectError(error.CyclicPlaceholder, Template.parse(std.testing.allocator, "${1:$2}${2:$1}", .{}));
    try std.testing.expectError(error.UnsupportedNestedFinalStop, Template.parse(std.testing.allocator, "${1:$0}", .{}));
    try std.testing.expectError(error.DepthExceeded, Template.parse(std.testing.allocator, "${1:${2:x}}", .{ .depth = 1 }));
    try std.testing.expectError(error.NodesFull, Template.parse(std.testing.allocator, "a$1", .{ .nodes = 1 }));
    try std.testing.expectError(error.OccurrencesFull, Template.parse(std.testing.allocator, "${1:${2:x}$2}$1", .{ .occurrences = 6 }));
    try std.testing.expectError(error.OutputCapacityExceeded, Template.parse(std.testing.allocator, "${1:$2$2}${2:$3$3}${3:xxxxxxxxxx}", .{ .output_bytes = 16 }));
}
test "explicit resolver snapshots literal values once and distinguishes unset empty unsupported" {
    var resolver: TestResolver = .{};
    const template = try Template.parseResolved(std.testing.allocator, "$X-$X", .{}, .{ .resolver = resolver.callback() });
    defer template.close() catch unreachable;
    try std.testing.expectEqualStrings("$1-$1", (try template.view()).text);
    try std.testing.expectEqual(@as(usize, 1), resolver.calls);
    for ([_]Resolution{ .value, .unset }) |resolution| {
        resolver = .{ .resolution = resolution, .text = "" };
        const value = try Template.parseResolved(std.testing.allocator, "${X:${1:a}} $1", .{}, .{ .resolver = resolver.callback() });
        defer value.close() catch unreachable;
        try std.testing.expectEqualStrings(if (resolution == .unset) "a a" else " ", (try value.view()).text);
    }
    resolver = .{ .resolution = .unsupported };
    try std.testing.expectError(error.UnsupportedVariable, Template.parseResolved(std.testing.allocator, "$X", .{}, .{ .resolver = resolver.callback() }));
    resolver = .{ .text = "abc" };
    try std.testing.expectError(error.VariableCapacityExceeded, Template.parseResolved(std.testing.allocator, "$X", .{ .variable_bytes = 2 }, .{ .resolver = resolver.callback() }));
    try std.testing.expectError(error.VariablesFull, Template.parseResolved(std.testing.allocator, "$X$Y", .{ .variables = 1 }, .{ .resolver = resolver.callback() }));
    resolver = .{ .text = &.{255} };
    try std.testing.expectError(error.InvalidUtf8, Template.parseResolved(std.testing.allocator, "$X", .{}, .{ .resolver = resolver.callback() }));
    resolver = .{ .text = &.{0} };
    try std.testing.expectError(error.EmbeddedNul, Template.parseResolved(std.testing.allocator, "$X", .{}, .{ .resolver = resolver.callback() }));
    var cancellation: Cancellation = .{};
    resolver = .{ .resolution = .unset, .cancellation = &cancellation };
    try std.testing.expectError(error.Cancelled, Template.parseResolved(std.testing.allocator, "${X:${1:a}}", .{}, .{ .resolver = resolver.callback(), .cancellation = &cancellation }));
}
fn nestedCandidate(allocator: std.mem.Allocator) !void {
    var resolver: TestResolver = .{ .resolution = .unset };
    const template = try Template.parseResolved(allocator, "${1:${NAME:${2:猫}}} $1 $2", .{}, .{ .resolver = resolver.callback() });
    defer template.close() catch unreachable;
    try std.testing.expectEqualStrings("猫 猫 猫", (try template.view()).text);
}
test "nested resolver candidate rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, nestedCandidate, .{});
}

const CancelOnInputFree = struct {
    source: std.mem.Allocator,
    cancellation: *Cancellation,
    input: ?[*]u8 = null,
    triggered: bool = false,
    fn allocator(self: *CancelOnInputFree) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CancelOnInputFree = @ptrCast(@alignCast(ptr));
        const result = self.source.rawAlloc(len, alignment, ret) orelse return null;
        if (self.input == null) self.input = result;
        return result;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CancelOnInputFree = @ptrCast(@alignCast(ptr));
        if (!self.triggered and bytes.ptr == self.input.?) {
            self.triggered = true;
            self.cancellation.request();
        }
        self.source.rawFree(bytes, alignment, ret);
    }
};
test "cancellation during final foreign preparation cleanup cannot publish a template" {
    for ([_][]const u8{ "${1:a${2:b}}$1", "${1:ab} ${1/(.*)/${1:/upcase}/}$0" }) |source| {
        var cancellation: Cancellation = .{};
        var hook: CancelOnInputFree = .{ .source = std.testing.allocator, .cancellation = &cancellation };
        try std.testing.expectError(error.Cancelled, Template.parseResolved(hook.allocator(), source, .{}, .{ .cancellation = &cancellation }));
        try std.testing.expect(hook.triggered);
    }
}

test "compiled transforms own regex format and preserve leaf source occurrences" {
    const template = try Template.parse(std.testing.allocator, "${1:ab} ${1/(.*)/${1:/upcase}/} ${2:next}$0", .{});
    defer template.close() catch unreachable;
    const view = try template.view();
    try std.testing.expectEqualStrings("ab ab next", view.text);
    try std.testing.expectEqual(@as(usize, 1), view.transforms.len);
    try std.testing.expectEqual(@as(?usize, 0), view.occurrences[1].transform_index);
    try std.testing.expectError(error.UnsupportedTransformSource, Template.parse(std.testing.allocator, "${1:a${2:b}} ${1/(.*)/$1/}", .{}));
    try std.testing.expectError(error.UnsupportedFinalTransform, Template.parse(std.testing.allocator, "${0/x/y/}", .{}));
    try std.testing.expectError(error.TransformsFull, Template.parse(std.testing.allocator, "${1/x/y/}", .{ .transforms = 0 }));
    try std.testing.expectError(error.UnclosedTransform, Template.parse(std.testing.allocator, "${1/x/y}", .{}));
    try std.testing.expectError(error.UnsupportedRegex, Template.parse(std.testing.allocator, "${1/(a)\\1/$1/}", .{}));
}
fn transformTemplateCandidate(allocator: std.mem.Allocator) !void {
    var resolver: TestResolver = .{ .text = "cat-file.txt" };
    const template = try Template.parseResolved(allocator, "${NAME/(.*)\\..+$/${1:/upcase}/} ${1:${NAME}} ${1/(.*)/<$1>/}$0", .{}, .{ .resolver = resolver.callback() });
    defer template.close() catch unreachable;
    try std.testing.expectEqualStrings("CAT-FILE cat-file.txt cat-file.txt", (try template.view()).text);
    try std.testing.expectEqual(@as(usize, 1), resolver.calls);
}
test "variable transforms snapshot raw resolver value once and all candidates roll back" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, transformTemplateCandidate, .{});
    var resolver: TestResolver = .{ .resolution = .unset };
    const template = try Template.parseResolved(std.testing.allocator, "${NAME/x/${1:-none}/}", .{}, .{ .resolver = resolver.callback() });
    defer template.close() catch unreachable;
    try std.testing.expectEqualStrings("none", (try template.view()).text);
}
