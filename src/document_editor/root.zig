const std = @import("std");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const ix = @import("index.zig");
const cache = @import("cache.zig");
const password_mask = @import("mask.zig");
const memory = @import("memory.zig");
const folding = @import("folds.zig");
const owner_commands = @import("owner_commands.zig");
const line_backgrounds = @import("line_backgrounds.zig");
const range_markers = @import("range_markers.zig");
const prepared_hit = @import("ziggurat_prepared_hit");
const pointer_selection = @import("pointer_selection.zig");
pub const RangeMarker = range_markers.Marker;
pub const RangeMarkerKind = range_markers.Kind;
pub const RangeMarkerMark = struct { marker: usize, range: d.Range, kind: RangeMarkerKind, color: u32, rect: Rect };
pub const RangeMarkerResult = struct { version: u64, current: bool };
pub const PreparedRangeMarkers = struct { items: []const RangeMarkerMark, version: u64, text_version: u64, view_version: u64, projection_version: u64 };
pub const LineBackground = line_backgrounds.Background;
pub const LineBackgroundMark = struct { paragraph: usize, color: u32, rect: Rect };
/// A successful result has installed the metadata. Old-resource disposal may
/// change the Document; current=false requires explicit host recomputation.
pub const LineBackgroundResult = struct { current: bool };
/// Text/native-change slices are borrowed only for this synchronous callback.
/// Legacy edit_key/key compatibility events do not invoke a second key hook.
pub const PreInput = union(enum) { key: z.KeyInput, text: z.TextInput, preedit: z.TextPreedit, native_change: z.text.Change };
pub const PreInputDecision = enum { pass, consume };
/// Borrow context until explicitly cleared or Adapter.close succeeds. A closed
/// Window alone does not release this borrow. Reentrant input is Busy.
pub const PreInputHook = struct { context: *anyopaque, call: *const fn (*anyopaque, z.Window, *Adapter, PreInput) PreInputDecision };
const HookOutcome = enum { pass, rejected, superseded };
pub const caret_visual = @import("ziggurat_caret");
pub const Command = owner_commands.Command;
pub const CommandGate = owner_commands.Gate;
pub const CommandOutcome = owner_commands.Outcome;
pub const projection = @import("projection.zig");
pub const ProjectionPlan = projection.Plan;
pub const Fold = folding.Fold;
pub const Rect = ui.Rect;
pub const Point = ui.layout.Point;
const max_batches = 24;
const max_scroll_x = 16 * 1024 * 1024;
pub const Limits = struct {
    paragraphs: usize = 262144,
    nodes: usize = 2097152,
    bytes: usize = 128 * 1024 * 1024,
    batches: usize = 24,
    batch_rows: usize = 32,
    batch_bytes: usize = 8192,
    paragraph_bytes: usize = 65536,
    shaped_bytes: usize = 256 * 1024,
    visual_stops: usize = 16386,
    rectangles: usize = 16384,
    caret_work: usize = 1024 * 1024,
    metadata_history: usize = 16,
    selections: usize = 64,
    batch_edits: usize = 4096,
    folds: usize = 4096,
    line_backgrounds: usize = 4096,
    range_markers: usize = 4096,
    range_marker_work: usize = 1024 * 1024,
    prepared: t.PrepareLimits = .{ .pixels = 1024 * 1024, .bytes = 8 * 1024 * 1024 },
};
pub const Parameters = struct { font: t.Options = .{ .wrap = .word_character, .width = 1 }, scale: f32 = 1, version: u64 = 0, estimated_height: f32 = 20, caret_cells: bool = false };
pub const Colors = struct { text: ui.Color = ui.Color.rgb(0x202020), selection: u32 = 0xc7ddff, composition: u32 = 0x385ca8, caret: u32 = 0x202020, caret_style: ?caret_visual.Style = null };
pub const EditResult = struct { changed: bool, index_required: bool };
pub const PrepareResult = struct { changed: bool, shaped_batches: usize, shaped_bytes: usize, index_rebuilt: bool };
/// Error returns precede ownership publication. Once published, foreign old
/// resource disposal can invalidate the result, but cannot undo its ownership.
pub const PairResult = struct { sides: [2]PrepareResult, current: bool, post_publish_error: ?anyerror };
pub const NativeChange = struct { revision: u64, layout_error: ?anyerror };
/// A completed selection is never retried after a presentation failure.
/// handled=false permits another consumer, not a replay through handleEvent.
pub const PointerResult = struct {
    handled: bool,
    selection_committed: bool = false,
    input_error: ?anyerror = null,
    presentation_error: ?anyerror = null,
};
pub const PresentationLease = @import("presentation_lease.zig").Lease;
pub const NativeObserver = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque, z.Window, *Adapter, NativeChange) anyerror!void,
    /// Read-only authority gate. The returned generation must remain equal
    /// across foreign calls and final commit; it must not track normal edits.
    validate: ?*const fn (*anyopaque, z.Window, *Adapter, ?ui.SpaceBinding) anyerror!?u64 = null,
};
pub const NativeObserverToken = struct { adapter: *Adapter, generation: u64 };
pub const FoldToken = struct { adapter: *Adapter, generation: u64 };
/// Errors precede both fold publications. A returned value means ownership was
/// committed even when foreign old-resource disposal invalidated current text.
pub const FoldPairResult = struct { current: bool, post_publish_error: ?anyerror };
pub const Status = struct { revision: u64, index_required: bool, folds_required: bool, fold_version: u64, layout_required: bool, last_layout_error: ?anyerror, projection_active: bool = false, line_backgrounds_required: bool = false, range_markers_required: bool = false };
pub const Stats = struct { owned_bytes: usize, reserved_peak_bytes: usize, nodes: usize, paragraphs: usize, layouts: usize, shaped_batches: u64, shaped_bytes: u64, visited_nodes: u64, reclaimed_nodes: u64, scanned_rows: u64, folds: usize, fold_version: u64, visible_paragraphs: usize, estimated_extent: f64 };
const Anchor = struct { line: usize = 0, id: u64 = 0, intra: f64 = 0 };
const VisualCaret = struct { selected: d.Selection, affinity: t.Affinity = .downstream, preferred_x: ?f32 = null };
const Movement = struct { selected: d.Selection, affinity: t.Affinity, preferred_x: ?f32, primary: bool = false };
const Receipt = struct { before: *ix.Node, after: *ix.Node, before_folds: ?*folding.Set, after_folds: ?*folding.Set };
const BatchMode = enum { mapped, selections, composition };
const NativeInput = struct { window: z.Window, token: ?z.TextClientToken, space: ?ui.SpaceBinding, space_generation: u64, input_stamp: z.TextInputStamp, observer_generation: u64, authority: ?u64 };
/// Linear main-thread borrow. End in reverse nesting order before releasing
/// the Adapter. This pins lifetime, while every mutation rechecks permission.
pub const NativeInputScope = struct {
    state: ?*State,
    previous: ?NativeInput,
    window_scope: z.CallbackScope,
    pub fn end(self: *NativeInputScope) void {
        const value = self.state orelse return;
        std.debug.assert(std.Thread.getCurrentId() == value.owner and !value.busy and value.clients != 0);
        self.state = null;
        value.native_input = self.previous;
        value.clients -= 1;
        // This may run unbound/on_closed and release the Adapter.
        self.window_scope.end();
    }
};
const PointerNative = struct {
    guard: pointer_selection.Guard,
    window: z.Window,
    press: z.PointerPress,
    revision: u64,
};
const PointerOwner = struct {
    state: pointer_selection.State = .{},
    input: ?PointerNative = null,
    last_up: z.PointerPress = .{},
    // Disposition only: this binding did not consume this primary down.
    // Semantic cancellation cannot change where its paired release belongs.
    ignored_sequence: u64 = 0,
    selection_revision: u64 = 0,
    bound: bool = false,
};
/// Reusable fields own an Adapter; this is a private construction seam, not
/// another public pointer admission API. Context's entered recipient scope is
/// the only caller allowed to preserve a cold installation's sequence floor.
pub const Field = @import("field.zig").Field(FieldAccess);
pub const FieldOptions = @import("field.zig").Options;
pub const FieldPolicy = @import("field.zig").Policy;
pub const FieldDescription = @import("field.zig").Description;
const FieldAccess = struct {
    pub fn parameters(adapter: *Adapter) !Parameters {
        return savedParameters(try adapter.state());
    }
    pub fn preparePointer(adapter: *Adapter, window: z.Window) !void {
        const value = try adapter.state();
        try pointerCapability(value, value.font.get());
        const pin = window.beginCallback() orelse return error.Closed;
        defer pin.end();
        const before = pin.record.pointerSequenceHighWater() orelse return error.UnsupportedCapability;
        if (before == std.math.maxInt(u64)) return error.IdExhausted;
        value.busy = true;
        defer value.busy = false;
        var candidate: ?*PointerOwner = null;
        defer if (candidate) |created| value.allocator().destroy(created);
        const created = value.pointer_owner orelse blk: {
            const allocated = try value.allocator().create(PointerOwner);
            allocated.* = .{};
            candidate = allocated;
            break :blk allocated;
        };
        if (window.isClosed()) return error.Closed;
        const after = pin.record.pointerSequenceHighWater() orelse return error.UnsupportedCapability;
        var next = created.state;
        if (!created.bound) next = .{ .installation = created.state.installation, .serial = created.state.serial, .retired = created.state.retired };
        try next.install(pointerWindow(window), @max(before, after));
        created.state = next;
        created.bound = true;
        created.selection_revision = try value.document.version();
        value.pointer_owner = created;
        candidate = null;
    }
    pub fn activatePointer(adapter: *Adapter, scope: *ui.TextFieldScope) !void {
        try scope.validate();
        const value = try adapter.state();
        const owner = value.pointer_owner orelse return;
        const window = scope.window();
        try boundWindow(value, window);
        if (!scope.isPointerDown() or !owner.state.enabled) {
            const record = window.app.windows.get(window.key) orelse return error.Closed;
            const floor = if (scope.isPointerDown()) owner.state.floor else record.pointerSequenceHighWater() orelse return error.UnsupportedCapability;
            try owner.state.install(pointerWindow(window), floor);
        }
        try scope.validate();
        owner.bound = true;
        owner.selection_revision = try value.document.version();
        owner.input = null;
        owner.last_up = .{};
        owner.ignored_sequence = 0;
        value.dragging = false;
    }
};
test "field storage is explicit and rejects invalid single line values before registration" {
    std.testing.refAllDecls(Field);
    const engine = try t.Engine.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "initial", .{});
    defer document.close() catch unreachable;
    const field = try Field.create(std.testing.allocator, document, engine, .{});
    defer field.close() catch unreachable;
    var family = [_]u8{ 'S', 'a', 'n', 's' };
    var locale = [_]u8{ 'e', 'n' };
    try field.prepare(.{ .x = 8, .y = 8, .width = 160, .height = 40 }, .{ .font = .{ .family = &family, .locale = &locale } });
    @memset(&family, 'x');
    @memset(&locale, 'z');
    try std.testing.expectEqualStrings("Sans", field.parameters.font.family);
    try std.testing.expectEqualStrings("en", field.parameters.font.locale);
    try std.testing.expectError(error.FieldWordPolicyMismatch, field.prepare(.{ .x = 8, .y = 8, .width = 160, .height = 40 }, .{ .font = .{ .word_ranges = true } }));
    try field.setPolicy(.{ .read_only = true });
    try std.testing.expectEqual(@as(u64, 2), field.policy_generation);
    try document.replace(.{ .start = 0, .end = 0 }, "\n");
    try std.testing.expectError(error.SingleLineRequired, field.prepare(.{ .x = 8, .y = 8, .width = 160, .height = 40 }, .{}));
    try std.testing.expectError(error.SingleLineRequired, Field.create(std.testing.allocator, document, engine, .{}));
    try std.testing.expectError(error.FieldBudgetExceeded, Field.create(std.testing.allocator, document, engine, .{ .storage_bytes = 1 }));
}

const FieldTestHost = struct {
    actions: usize = 0,
    changes: usize = 0,
    submits: usize = 0,
    close_on_change: ?*Field = null,
    close_error: ?anyerror = null,
    clipboard_bytes: [128]u8 = undefined,
    clipboard_len: usize = 0,
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(ptr: *anyopaque, _: u64) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.actions += 1;
    }
    fn changed(ptr: ?*anyopaque, _: z.Window, _: u64) void {
        const self: *@This() = @ptrCast(@alignCast(ptr.?));
        self.changes += 1;
        if (self.close_on_change) |field| {
            self.close_on_change = null;
            field.close() catch |err| {
                self.close_error = err;
            };
        }
    }
    fn submit(ptr: ?*anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr.?));
        self.submits += 1;
    }
    fn write(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (bytes.len > self.clipboard_bytes.len) return error.Full;
        @memcpy(self.clipboard_bytes[0..bytes.len], bytes);
        self.clipboard_len = bytes.len;
    }
    fn read(ptr: *anyopaque, output: []u8) !usize {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (output.len < self.clipboard_len) return error.Full;
        @memcpy(output[0..self.clipboard_len], self.clipboard_bytes[0..self.clipboard_len]);
        return self.clipboard_len;
    }
    fn front(context: *ui.Context, fields: []const *Field, button: bool) !void {
        const workspace = context.transforms.?;
        try workspace.state.beginFrame(context.space_generation + 1);
        errdefer workspace.state.cancelFrame();
        context.input_state.beginMappedFrame(try workspace.state.pending());
        errdefer context.input_state.cancelFrame();
        try context.command_buffer.bindTransformStorage(&workspace.command_storage);
        defer context.command_buffer.reset();
        var frame: ui.Frame = .{ .context = context, .size = .{ .width = 320, .height = 200, .scale = 1 }, .transforms = workspace };
        for (fields) |field| try field.draw(&frame, .{}, "Field");
        if (button) try frame.button(90, .{ .x = 210, .y = 10, .width = 80, .height = 30 }, "Other");
        try context.command_buffer.finish();
        try context.input_state.validateFrame();
        context.space_generation = try workspace.state.commitFrame();
        context.input_state.commitFrame();
    }
    fn emit(window: z.Window, event: z.Event) void {
        window.app.windows.get(window.key).?.emit(event);
    }
    fn text(document: *d.Document, expected: []const u8) !void {
        var buffer: [128]u8 = undefined;
        const count = try document.read(.{ .start = 0, .end = try document.byteLength() }, &buffer);
        try std.testing.expectEqualStrings(expected, buffer[0..count]);
    }
};
test "field final storage free rejects close reentry before touching the released Adapter" {
    const Hook = struct {
        field: ?*Field = null,
        address: usize = 0,
        fired: bool = false,
        failure: ?anyerror = null,
        fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!self.fired and @intFromPtr(bytes.ptr) == self.address) {
                self.fired = true;
                self.field.?.close() catch |err| {
                    self.failure = err;
                };
            }
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    const engine = try t.Engine.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "x", .{});
    defer document.close() catch unreachable;
    var hook: Hook = .{};
    const allocator: std.mem.Allocator = .{ .ptr = &hook, .vtable = &.{ .alloc = Hook.alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = Hook.free } };
    const field = try Field.create(allocator, document, engine, .{});
    hook.field = field;
    hook.address = @intFromPtr(field.storage.ptr);
    try field.close();
    try std.testing.expect(hook.fired);
    try std.testing.expect(hook.failure.? == error.ResourceInUse);
}
test "field construction releases every partial owner on allocator failure" {
    const FieldFailure = struct {
        fn create(allocator: std.mem.Allocator, document: *d.Document, engine: *t.Engine) !void {
            const field = try Field.create(allocator, document, engine, .{});
            try field.close();
        }
    };
    const engine = try t.Engine.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "owned", .{});
    defer document.close() catch unreachable;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, FieldFailure.create, .{ document, engine });
    const FieldInput = @FieldType(ui.Context, "input_state");
    std.debug.print("Document Field layouts: Field={d} AdapterState={d} Input={d} Context={d}; default registry pointer={d}\n", .{ @sizeOf(Field), @sizeOf(State), @sizeOf(FieldInput), @sizeOf(ui.Context), @sizeOf(@FieldType(FieldInput, "fields")) });
}
test "field constructor captures value limits and callbacks before the caller allocator" {
    const Hook = struct {
        options: *FieldOptions,
        changed: bool = false,
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!self.changed) {
                self.changed = true;
                self.options.value_bytes = 1;
                self.options.multiline = true;
                self.options.policy = .{ .enabled = false, .read_only = true };
                self.options.context = null;
                self.options.changed = null;
                self.options.submit = null;
                self.options.clipboard = null;
            }
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    const engine = try t.Engine.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "owned", .{});
    defer document.close() catch unreachable;
    var host: FieldTestHost = .{};
    var options: FieldOptions = .{ .value_bytes = 128, .context = &host, .changed = FieldTestHost.changed, .submit = FieldTestHost.submit, .clipboard = .{ .context = &host, .read = FieldTestHost.read, .write = FieldTestHost.write } };
    var hook: Hook = .{ .options = &options };
    const allocator: std.mem.Allocator = .{ .ptr = &hook, .vtable = &.{ .alloc = Hook.alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = Hook.free } };
    const field = try Field.create(allocator, document, engine, options);
    defer field.close() catch unreachable;
    try std.testing.expect(hook.changed);
    try std.testing.expectEqual(@as(usize, 128), field.value.len);
    try std.testing.expectEqual(@as(usize, 128), field.scratch.len);
    try std.testing.expect(!field.options.multiline and field.options.policy.enabled and !field.options.policy.read_only);
    try std.testing.expect(field.options.context == @as(?*anyopaque, &host) and field.options.changed == FieldTestHost.changed and field.options.submit == FieldTestHost.submit);
    try std.testing.expect(field.options.clipboard != null and field.options.clipboard.?.context == @as(*anyopaque, &host));
}
test "adapter constructor captures its validated limits before the caller allocator" {
    const Hook = struct {
        limits: *Limits,
        changed: bool = false,
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!self.changed) {
                self.changed = true;
                self.limits.bytes = 1;
                self.limits.selections = 0;
                self.limits.nodes = 0;
                self.limits.prepared.pixels = 0;
            }
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    const engine = try t.Engine.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "owned", .{});
    defer document.close() catch unreachable;
    var limits: Limits = .{ .selections = 3 };
    var hook: Hook = .{ .limits = &limits };
    const allocator: std.mem.Allocator = .{ .ptr = &hook, .vtable = &.{ .alloc = Hook.alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = Hook.free } };
    const adapter = try Adapter.create(allocator, document, engine, limits);
    defer adapter.close() catch unreachable;
    const value = try adapter.state();
    try std.testing.expect(hook.changed);
    try std.testing.expectEqual(@as(usize, 128 * 1024 * 1024), value.limits.bytes);
    try std.testing.expectEqual(@as(usize, 3), value.selection_buffer.len);
    try std.testing.expectEqual(@as(usize, 2097152), value.storage.node_limit);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), value.limits.prepared.pixels);
}
test "Document fields share control focus native text clipboard readonly and one undo authority" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var host: FieldTestHost = .{};
    var context = ui.Context.init(&host, FieldTestHost.draw, FieldTestHost.action);
    context.semantics_enabled = false;
    try context.attach(window);
    try context.prepareTextFields(std.testing.allocator, .{});
    const engine = try t.Engine.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const first = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "one", .{});
    defer first.close() catch unreachable;
    const second = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "two", .{});
    defer second.close() catch unreachable;
    const options: FieldOptions = .{ .context = &host, .changed = FieldTestHost.changed, .submit = FieldTestHost.submit, .clipboard = .{ .context = &host, .read = FieldTestHost.read, .write = FieldTestHost.write } };
    const a = try Field.create(std.testing.allocator, first, engine, options);
    defer a.close() catch unreachable;
    const b = try Field.create(std.testing.allocator, second, engine, options);
    defer b.close() catch unreachable;
    try a.prepare(.{ .x = 8, .y = 8, .width = 180, .height = 40 }, .{});
    try b.prepare(.{ .x = 8, .y = 60, .width = 180, .height = 40 }, .{});
    try a.attach(&context, 1);
    try b.attach(&context, 2);
    try FieldTestHost.front(&context, &.{ a, b }, true);
    try a.focus();
    try std.testing.expectEqual(@as(?u64, 1), context.input_state.focused);
    FieldTestHost.emit(window, .{ .text_input = .{ .text = "!", .producer = .application } });
    try FieldTestHost.text(first, "one!");
    try std.testing.expectEqual(@as(usize, 1), host.changes);
    try std.testing.expect(!context.handleKeyInput(window, .{ .key = .space }));
    try std.testing.expectEqual(@as(usize, 0), host.actions);
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .enter }));
    try std.testing.expectEqual(@as(usize, 1), host.submits);
    try FieldTestHost.text(first, "one!");
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .a, .modifiers = .{ .control = true } }));
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .c, .modifiers = .{ .control = true } }));
    try std.testing.expectEqualStrings("one!", host.clipboard_bytes[0..host.clipboard_len]);
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .tab }));
    try std.testing.expectEqual(@as(?u64, 2), context.input_state.focused);
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .a, .modifiers = .{ .control = true } }));
    try FieldTestHost.write(&host, "x\r\ny");
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .v, .modifiers = .{ .control = true } }));
    try FieldTestHost.text(second, "x y");
    try std.testing.expectEqual(@as(usize, 2), host.changes);
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .z, .modifiers = .{ .control = true } }));
    try FieldTestHost.text(second, "two");
    try std.testing.expectEqual(@as(usize, 3), host.changes);
    const invalid_before = try second.version();
    const writable = window.textClientToken().?;
    try std.testing.expectEqual(z.text.ChangeResult.rejected, try window.changeTextClient(writable, .{ .replace = .{ .range = .{ .start = 2, .end = 1 }, .text = "" } }));
    try std.testing.expectEqual(z.text.ChangeResult.rejected, try window.changeTextClient(writable, .{ .replace = .{ .range = .{ .start = 0, .end = 1000 }, .text = "" } }));
    try std.testing.expectEqual(invalid_before, try second.version());
    try b.blur();
    try std.testing.expect(context.input_state.focused == null and !try window.hasTextClient());
    try a.focus();
    try b.blur(); // Exact recipient: blurring B cannot clear A's focus/client.
    try std.testing.expectEqual(@as(?u64, 1), context.input_state.focused);
    try b.focus();
    try b.setPolicy(.{ .read_only = true });
    const before = try second.version();
    FieldTestHost.emit(window, .{ .text_input = .{ .text = "NO", .producer = .application } });
    const current = window.textClientToken().?;
    try std.testing.expectEqual(z.text.ChangeResult.rejected, try window.changeTextClient(current, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "NO" } }));
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .backspace }));
    for ([_]z.EditKey{ .{ .key = .backspace }, .{ .key = .delete }, .{ .key = .z, .control = true }, .{ .key = .y, .control = true } }) |key| FieldTestHost.emit(window, .{ .edit_key = key });
    try std.testing.expectError(error.ReadOnly, b.setValue("NO"));
    try std.testing.expectError(error.ReadOnly, b.undo());
    try std.testing.expectEqual(before, try second.version());
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .tab }));
    try std.testing.expectEqual(@as(?u64, 90), context.input_state.focused);
    try std.testing.expect(!try window.hasTextClient());
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .space }));
    try std.testing.expectEqual(@as(usize, 1), host.actions);
    const stats = try context.transformStats();
    try std.testing.expect(!stats.layers.software.prepared and stats.layers.current_bytes == 0);
}
test "password fields shape placeholders, copy nothing, hide text from input services and turn the input method off" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var host: FieldTestHost = .{};
    var context = ui.Context.init(&host, FieldTestHost.draw, FieldTestHost.action);
    context.semantics_enabled = false;
    try context.attach(window);
    try context.prepareTextFields(std.testing.allocator, .{});
    const engine = try t.Engine.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "s\xc3\xa9", .{});
    defer document.close() catch unreachable;
    const field = try Field.create(std.testing.allocator, document, engine, .{ .password = true, .clipboard = .{ .context = &host, .read = FieldTestHost.read, .write = FieldTestHost.write } });
    defer field.close() catch unreachable;
    const bounds: Rect = .{ .x = 8, .y = 8, .width = 180, .height = 40 };
    try field.prepare(bounds, .{});
    try field.attach(&context, 1);
    try FieldTestHost.front(&context, &.{field}, false);
    const shaped = struct {
        fn text(adapter: *Adapter) ![]const u8 {
            const value = try adapter.state();
            return value.view.?.blocks[0].entry.layout.text();
        }
    };
    try std.testing.expectEqualStrings("o\xce\xbf", try shaped.text(field.adapter));
    try field.focus();
    try std.testing.expectEqual(z.TextInputMode.keyboard_compose, try window.textInputMode());
    FieldTestHost.emit(window, .{ .text_input = .{ .text = "!", .producer = .application } });
    try FieldTestHost.text(document, "s\xc3\xa9!");
    var storage: [64]u8 = undefined;
    const snapshot = try window.readTextClient(window.textClientToken().?, &storage);
    try std.testing.expect(std.mem.indexOf(u8, storage[0..snapshot.bytes], "s") == null and std.mem.indexOf(u8, storage[0..snapshot.bytes], "!") == null);
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .a, .modifiers = .{ .control = true } }));
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .c, .modifiers = .{ .control = true } }));
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .x, .modifiers = .{ .control = true } }));
    try std.testing.expectEqual(@as(usize, 0), host.clipboard_len);
    try FieldTestHost.text(document, "s\xc3\xa9!");
    try FieldTestHost.write(&host, "pw");
    try std.testing.expect(context.handleKeyInput(window, .{ .key = .v, .modifiers = .{ .control = true } }));
    try FieldTestHost.text(document, "pw");
    // Showing the password turns the input method back on and shapes the
    // text itself at the next prepare.
    try field.setPassword(false);
    try std.testing.expectEqual(z.TextInputMode.system, try window.textInputMode());
    try field.prepare(bounds, .{});
    try std.testing.expectEqualStrings("pw", try shaped.text(field.adapter));
    try field.setPassword(true);
    try std.testing.expectEqual(z.TextInputMode.keyboard_compose, try window.textInputMode());
    try field.blur();
    try std.testing.expectEqual(z.TextInputMode.system, try window.textInputMode());
    try field.prepare(bounds, .{});
    try std.testing.expectEqualStrings("oo", try shaped.text(field.adapter));
}
test "field callback close retires before slot reuse and old close retry never withdraws new registration" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var host: FieldTestHost = .{};
    var context = ui.Context.init(&host, FieldTestHost.draw, FieldTestHost.action);
    context.semantics_enabled = false;
    try context.attach(window);
    try context.prepareTextFields(std.testing.allocator, .{ .fields = 1 });
    const engine = try t.Engine.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "old", .{});
    defer document.close() catch unreachable;
    const replacement = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "new", .{});
    defer replacement.close() catch unreachable;
    const old = try Field.create(std.testing.allocator, document, engine, .{ .context = &host, .changed = FieldTestHost.changed });
    var old_alive = true;
    defer if (old_alive) old.close() catch unreachable;
    const bounds: Rect = .{ .x = 8, .y = 8, .width = 160, .height = 40 };
    try old.prepare(bounds, .{});
    try old.attach(&context, 7);
    try FieldTestHost.front(&context, &.{old}, false);
    try old.focus();
    const previous = old.token.?;
    host.close_on_change = old;
    FieldTestHost.emit(window, .{ .text_input = .{ .text = "!", .producer = .application } });
    try std.testing.expect(host.close_error.? == error.ResourceInUse);
    try std.testing.expectError(error.StaleTextField, previous.validate());
    const fresh = try Field.create(std.testing.allocator, replacement, engine, .{});
    defer fresh.close() catch unreachable;
    try fresh.prepare(bounds, .{});
    try fresh.attach(&context, 7);
    try FieldTestHost.front(&context, &.{fresh}, false);
    try std.testing.expect(fresh.token.?.key.serial != previous.key.serial);
    // The old physical TextClient is still owned until close can be retried;
    // a new registration is not permission to steal an unrelated client.
    try std.testing.expectError(error.TextClientActive, fresh.focus());
    try old.close();
    old_alive = false;
    try fresh.focus();
    try fresh.token.?.validate();
    FieldTestHost.emit(window, .{ .text_input = .{ .text = "!", .producer = .application } });
    try FieldTestHost.text(replacement, "new!");
}
const OwnedFont = struct {
    options: t.Options = .{},
    family: [255]u8 = undefined,
    locale: [127]u8 = undefined,
    family_len: usize = 0,
    locale_len: usize = 0,
    fn get(self: *const OwnedFont) t.Options {
        var result = self.options;
        result.family = self.family[0..self.family_len];
        result.locale = self.locale[0..self.locale_len];
        return result;
    }
    fn set(self: *OwnedFont, value: t.Options) void {
        self.options = value;
        self.options.family = "";
        self.options.locale = "";
        self.family_len = value.family.len;
        self.locale_len = value.locale.len;
        std.mem.copyForwards(u8, self.family[0..self.family_len], value.family);
        std.mem.copyForwards(u8, self.locale[0..self.locale_len], value.locale);
    }
};
const Block = struct { entry: *cache.Entry, prepared: *cache.Prepared, line: usize, byte: usize, y: f64 };
const ParagraphPlacement = struct { block: usize, line: usize, range: d.Range, native_top: f64, y: f64, height: f64 };
pub const FoldHeaderMark = struct { id: u64, collapsed: bool, rect: Rect };
pub const CaretMark = struct { selection: usize, primary: bool, rect: Rect };
/// Cached advance geometry, in the Adapter's layout DIP space (window DIP by
/// default, local DIP when an explicit committed Space binding is installed).
/// A grapheme may have several cells; these are not glyph ink or caret stops.
pub const GeometryCell = struct { range: d.Range, rect: Rect };
pub const PreparedGeometry = struct { cells: []const GeometryCell, bounds: Rect, scale: f32, projection_version: u64 };
pub const GeometryOptions = struct { paragraphs: ?[]const usize = null };
pub const GeometryCaret = struct { position: usize, affinity: t.Affinity, rect: Rect };
pub const GeometryLine = struct { first: usize, count: usize, rect: Rect };
pub const PreparedCarets = struct { carets: []const GeometryCaret, lines: []const GeometryLine, bounds: Rect, scale: f32, projection_version: u64 };
pub const HitBlock = prepared_hit.Block;
pub const HitLine = prepared_hit.Line;
pub const HitStop = prepared_hit.Stop;
pub const HitPlacement = prepared_hit.Placement;
pub const HitPacket = prepared_hit.Packet;
/// Caller-owned, nonoverlapping arrays. On failure none of their records change.
/// The successful descriptor borrows only these arrays; keep them immutable and
/// alive while reading it, independently of Adapter, Document or Engine.
pub const PreparedHitBuffers = struct { blocks: []HitBlock, lines: []HitLine, stops: []HitStop, placements: []HitPlacement };
pub const PreparedHit = struct { packet: HitPacket, revision: u64, text_version: u64, projection_version: u64, geometry_generation: u64, scale: f32 };
const Mark = struct { rect: Rect, kind: enum { selection, composition } };
const CaretVisual = struct { native: Rect, clip: Rect, first: usize, count: usize, collapsed: bool };
const View = struct {
    blocks: [max_batches]Block = undefined,
    count: usize = 0,
    marks: []Mark = &.{},
    carets: []CaretMark = &.{},
    caret_visuals: []CaretVisual = &.{},
    caret_cells: []caret_visual.Rect = &.{},
    cells_enabled: bool = false,
    headers: []FoldHeaderMark = &.{},
    caret: ?Rect = null,
    bounds: Rect,
    scale: f32,
    revision: u64,
    text_version: u64 = 0,
    composition_revision: ?u64 = null,
    geometry_generation: u64 = 0,
    fold_version: u64 = 0,
    scroll_x: f64 = 0,
    placements: []ParagraphPlacement = &.{},
    line_backgrounds: []LineBackgroundMark = &.{},
    range_markers: []RangeMarkerMark = &.{},
    range_marker_version: u64 = 0,
    /// With foreground markers, where each run's text draws in which color:
    /// the marker rectangles and the rest of the run in the text color.
    text_clips: []TextClip = &.{},
    projected: bool = false,
    projection_root: ?*ix.Node = null,
    fn ensureUnused(self: *const View) !void {
        for (self.blocks[0..self.count]) |block| try block.prepared.value.ensureUnused();
    }
    fn close(self: *View, allocator: std.mem.Allocator) void {
        for (self.blocks[0..self.count]) |block| {
            block.prepared.release();
            block.entry.release();
        }
        allocator.free(self.marks);
        allocator.free(self.carets);
        allocator.free(self.caret_visuals);
        allocator.free(self.caret_cells);
        allocator.free(self.headers);
        allocator.free(self.placements);
        allocator.free(self.line_backgrounds);
        allocator.free(self.range_markers);
        allocator.free(self.text_clips);
    }
};
/// One clip of a run's text pass; a null color is the text color.
const TextClip = struct { rect: Rect, color: ?u32, run: u32 };
const VisualRun = struct {
    block: *const Block,
    range: d.Range,
    y: f64,
    clip: Rect,
    paragraph: ?usize = null,
    last: bool,
};
const RunIterator = struct {
    view: *const View,
    at: usize = 0,
    fn next(self: *RunIterator) !?VisualRun {
        const view = self.view;
        if (view.projected) {
            if (self.at == view.placements.len) return null;
            const placement = view.placements[self.at];
            self.at += 1;
            return .{ .block = &view.blocks[placement.block], .range = placement.range, .y = placement.y - placement.native_top, .clip = ui.layout.intersect(view.bounds, .{ .x = view.bounds.x, .y = @floatCast(@as(f64, view.bounds.y) + placement.y), .width = view.bounds.width, .height = @floatCast(placement.height) }), .paragraph = placement.line, .last = self.at == view.placements.len };
        }
        if (self.at == view.count) return null;
        const block = &view.blocks[self.at];
        self.at += 1;
        return .{ .block = block, .range = .{ .start = block.byte, .end = block.byte + (try block.entry.layout.text()).len }, .y = block.y, .clip = view.bounds, .last = self.at == view.count };
    }
};
fn rangeInRun(run: VisualRun, range: d.Range) !?t.ByteRange {
    if (range.start >= run.range.end or range.end <= run.range.start or range.start == range.end) return null;
    return .{ .start = try cache.snap(run.block.entry.layout, @max(range.start, run.range.start) - run.block.byte, false), .end = try cache.snap(run.block.entry.layout, @min(range.end, run.range.end) - run.block.byte, true) };
}
fn rangeRect(view: *const View, scroll_x: f64, run: VisualRun, item: t.Rect) Rect {
    return ui.layout.intersect(.{ .x = @floatCast(@as(f64, view.bounds.x) + item.x - scroll_x), .y = @floatCast(@as(f64, view.bounds.y) + run.y + item.y), .width = item.width, .height = item.height }, run.clip);
}
fn preparedRangeRects(view: *const View, scroll_x: f64, range: d.Range, destination: []t.Rect) ![]const t.Rect {
    if (range.start == range.end) return destination[0..0];
    var count: usize = 0;
    var runs: RunIterator = .{ .view = view };
    while (try runs.next()) |run| {
        const block = run.block;
        const local = try rangeInRun(run, range) orelse continue;
        const needed = try block.entry.layout.selectionRectCount(local);
        if (needed > destination.len -| count) return error.RectangleCapacityExceeded;
        count += needed;
    }
    var at: usize = 0;
    runs.at = 0;
    while (try runs.next()) |run| {
        const block = run.block;
        const local = try rangeInRun(run, range) orelse continue;
        for (try block.entry.layout.selectionRects(local, destination[at..])) |item| {
            const clipped = rangeRect(view, scroll_x, run, item);
            if (clipped.width > 0 and clipped.height > 0) {
                destination[at] = .{ .x = clipped.x, .y = clipped.y, .width = clipped.width, .height = clipped.height };
                at += 1;
            }
        }
    }
    return destination[0..at];
}
fn preparedPositionRect(value: *State, view: *const View, root: *ix.Node, scroll_x: f64, position: usize, affinity: t.Affinity) !?t.Rect {
    if (ix.get(&value.storage, root, ix.lineAt(&value.storage, root, position)).hidden) return null;
    var runs: RunIterator = .{ .view = view };
    while (try runs.next()) |run| {
        const block = run.block;
        if (run.paragraph) |line| {
            if (line != paragraphFor(value, root, position, affinity)) continue;
        } else if (position < run.range.start or position > run.range.end or (position == run.range.end and affinity == .downstream and !run.last)) continue;
        const native = try block.entry.layout.caret(.{ .byte_offset = try cache.snap(block.entry.layout, position - block.byte, true), .affinity = affinity });
        const clipped = ui.layout.intersect(.{ .x = @floatCast(@as(f64, view.bounds.x) + native.x - scroll_x), .y = @floatCast(@as(f64, view.bounds.y) + run.y + native.y), .width = @max(1, native.width), .height = native.height }, run.clip);
        if (clipped.width > 0 and clipped.height > 0) return .{ .x = clipped.x, .y = clipped.y, .width = clipped.width, .height = clipped.height };
    }
    return null;
}
fn copyPreparedGeometry(view: *const View, scroll_x: f64, options: GeometryOptions, output: ?[]GeometryCell) !usize {
    var count: usize = 0;
    var placement_start: usize = 0;
    for (view.blocks[0..view.count], 0..) |block, block_index| {
        while (placement_start < view.placements.len and view.placements[placement_start].block < block_index) : (placement_start += 1) {}
        var placement_end = placement_start;
        while (placement_end < view.placements.len and view.placements[placement_end].block == block_index) : (placement_end += 1) {}
        for (try block.entry.layout.advanceSpans()) |span| {
            const range: d.Range = .{ .start = block.byte + span.start, .end = block.byte + span.end };
            var y = block.y;
            var clip = view.bounds;
            if (view.projected) {
                // Span order is visual; source paragraph selection is binary,
                // rather than rescanning every batch for every placement.
                var lo = placement_start;
                var hi = placement_end;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (view.placements[mid].range.end <= range.start) lo = mid + 1 else hi = mid;
                }
                if (lo == placement_end) continue;
                const placement = view.placements[lo];
                if (range.start < placement.range.start or range.end > placement.range.end) continue;
                if (options.paragraphs) |paragraphs| {
                    var first: usize = 0;
                    var last = paragraphs.len;
                    while (first < last) {
                        const mid = first + (last - first) / 2;
                        if (paragraphs[mid] < placement.line) first = mid + 1 else last = mid;
                    }
                    if (first == paragraphs.len or paragraphs[first] != placement.line) continue;
                }
                y = placement.y - placement.native_top;
                clip = ui.layout.intersect(view.bounds, .{ .x = view.bounds.x, .y = @floatCast(@as(f64, view.bounds.y) + placement.y), .width = view.bounds.width, .height = @floatCast(placement.height) });
            }
            const rect = ui.layout.intersect(.{ .x = @floatCast(@as(f64, view.bounds.x) + span.rect.x - scroll_x), .y = @floatCast(@as(f64, view.bounds.y) + y + span.rect.y), .width = span.rect.width, .height = span.rect.height }, clip);
            if (rect.width <= 0 or rect.height <= 0) continue;
            if (output) |destination| destination[count] = .{ .range = range, .rect = rect };
            count += 1;
        }
    }
    return count;
}
const CaretCounts = struct { carets: usize = 0, lines: usize = 0 };
fn copyPreparedCarets(value: *State, view: *const View, options: GeometryOptions, carets: ?[]GeometryCaret, lines: ?[]GeometryLine) !CaretCounts {
    const root = try value.currentIndex();
    var result: CaretCounts = .{};
    var placement_start: usize = 0;
    for (view.blocks[0..view.count], 0..) |block, block_index| {
        while (placement_start < view.placements.len and view.placements[placement_start].block < block_index) : (placement_start += 1) {}
        var placement_end = placement_start;
        while (placement_end < view.placements.len and view.placements[placement_end].block == block_index) : (placement_end += 1) {}
        const native_lines = try block.entry.layout.lines();
        var at: usize = 0;
        while (at < block.entry.stops.len) {
            const first = at;
            const visual_line = block.entry.stops[at].line;
            while (at < block.entry.stops.len and block.entry.stops[at].line == visual_line) : (at += 1) {}
            const native_line = native_lines[visual_line];
            const paragraph = ix.lineAt(&value.storage, root, block.byte + native_line.start);
            // A terminated batch can have a layout-only final empty line.
            // Only the batch containing the actual Document row exports it.
            if (paragraph < block.line or paragraph - block.line >= block.entry.row_count) continue;
            var y = block.y;
            var clip = view.bounds;
            if (view.projected) {
                var lo = placement_start;
                var hi = placement_end;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (view.placements[mid].line < paragraph) lo = mid + 1 else hi = mid;
                }
                if (lo == placement_end or view.placements[lo].line != paragraph) continue;
                if (options.paragraphs) |paragraphs| {
                    var low: usize = 0;
                    var high = paragraphs.len;
                    while (low < high) {
                        const mid = low + (high - low) / 2;
                        if (paragraphs[mid] < paragraph) low = mid + 1 else high = mid;
                    }
                    if (low == paragraphs.len or paragraphs[low] != paragraph) continue;
                }
                const placement = view.placements[lo];
                y = placement.y - placement.native_top;
                clip = ui.layout.intersect(view.bounds, .{ .x = view.bounds.x, .y = @floatCast(@as(f64, view.bounds.y) + placement.y), .width = view.bounds.width, .height = @floatCast(placement.height) });
            }
            const line_bounds = ui.layout.intersect(.{ .x = view.bounds.x, .y = @floatCast(@as(f64, view.bounds.y) + y + native_line.y), .width = view.bounds.width, .height = native_line.height }, clip);
            if (line_bounds.width <= 0 or line_bounds.height <= 0) continue;
            const start = result.carets;
            for (block.entry.stops[first..at], first..) |stop, index| {
                if (block.byte != 0 and index == block.entry.first_upstream) continue;
                const x = @as(f64, view.bounds.x) + stop.rect.x - value.scroll_x;
                const top = @max(@as(f64, clip.y), @as(f64, view.bounds.y) + y + stop.rect.y);
                const bottom = @min(@as(f64, clip.y) + clip.height, @as(f64, view.bounds.y) + y + stop.rect.y + stop.rect.height);
                if (x < clip.x or x > @as(f64, clip.x) + clip.width or bottom <= top) continue;
                if (carets) |destination| destination[result.carets] = .{ .position = block.byte + stop.caret.byte_offset, .affinity = stop.caret.affinity, .rect = .{ .x = @floatCast(x), .y = @floatCast(top), .width = 0, .height = @floatCast(bottom - top) } };
                result.carets += 1;
            }
            if (result.carets != start) {
                if (lines) |destination| destination[result.lines] = .{ .first = start, .count = result.carets - start, .rect = line_bounds };
                result.lines += 1;
            }
        }
    }
    return result;
}
fn geometryView(value: *State, expected_revision: u64, options: GeometryOptions) !*View {
    if (expected_revision != try value.document.version()) return error.StaleRevision;
    if (try value.document.composition() != null) return error.CompositionActive;
    if (value.layout_required or value.observed != expected_revision) return error.LayoutRequired;
    const view = if (value.view) |*prepared| prepared else return error.LayoutRequired;
    if (view.revision != expected_revision) return error.StaleRevision;
    if (options.paragraphs) |paragraphs| {
        if (!view.projected) return error.ProjectionRequired;
        if (paragraphs.len > max_batches * cache.max_rows) return error.VisibleCapacityExceeded;
        const count = ix.sum(value.overlay orelse value.committed).rows;
        for (paragraphs, 0..) |line, at| if (line >= count or (at != 0 and line <= paragraphs[at - 1])) return error.InvalidParagraphs;
    }
    return view;
}
fn projectionEqual(a: *const View, b: *const View) bool {
    if (a.text_version != b.text_version or a.composition_revision != b.composition_revision or a.geometry_generation != b.geometry_generation or a.fold_version != b.fold_version or a.scroll_x != b.scroll_x or a.scale != b.scale or a.projected != b.projected or a.projection_root != b.projection_root or !std.meta.eql(a.bounds, b.bounds) or a.count != b.count) return false;
    if (a.placements.len != b.placements.len) return false;
    for (a.placements, b.placements) |left, right| if (!std.meta.eql(left, right)) return false;
    for (a.blocks[0..a.count], b.blocks[0..b.count]) |left, right| {
        if (left.entry != right.entry or left.byte != right.byte or left.line != right.line or left.y != right.y) return false;
    }
    return true;
}
const State = struct {
    budget: *memory.Budget,
    owner: std.Thread.Id,
    document: *d.Document,
    engine: *t.Engine,
    limits: Limits,
    storage: ix.Storage,
    committed: ?*ix.Node = null,
    overlay: ?*ix.Node = null,
    overlay_folds: ?*folding.Set = null,
    next_id: u64 = 1,
    next_epoch: u64 = 1,
    observed: u64,
    folds: ?*folding.Set = null,
    pending_folds: ?*folding.Set = null,
    pending_fold_restore: bool = false,
    folds_required: bool = false,
    fold_version: u64 = 0,
    fold_owner: ?u64 = null,
    fold_generation: u64 = 0,
    line_backgrounds: []LineBackground = &.{},
    background_text_version: ?u64 = null,
    range_markers: []range_markers.Entry = &.{},
    marker_text_version: ?u64 = null,
    range_marker_version: u64 = 0,
    busy: bool = false,
    clients: usize = 0,
    index_required: bool = false,
    layout_required: bool = true,
    last_layout_error: ?anyerror = null,
    anchor: Anchor = .{},
    scroll_x: f64 = 0,
    affinity: t.Affinity = .downstream,
    preferred_x: ?f32 = null,
    reveal: bool = false,
    dragging: bool = false,
    token: ?z.TextClientToken = null,
    native_space: ?ui.SpaceBinding = null,
    native_input: ?NativeInput = null,
    owner_command: ?*owner_commands.Capture = null,
    pointer_owner: ?*PointerOwner = null,
    native_observer: ?NativeObserver = null,
    pre_input: ?PreInputHook = null,
    pre_input_running: bool = false,
    observer_generation: u64 = 0,
    history: []Receipt,
    selection_buffer: []d.Selection,
    visual: []VisualCaret,
    visual_count: usize = 0,
    visual_revision: u64 = 0,
    history_start: usize = 0,
    history_len: usize = 0,
    history_cursor: usize = 0,
    entries: [max_batches]?*cache.Entry = @splat(null),
    entry_count: usize = 0,
    view: ?View = null,
    font: OwnedFont = .{},
    configured: bool = false,
    caret_cells: bool = false,
    /// Password text: shaped as placeholders and drawn as bullets. The
    /// committed view was shaped with `mask_shaped`.
    masked: bool = false,
    mask_shaped: bool = false,
    projected_plan: ?*projection.Plan = null,
    projected_geometry: ?projection.Geometry = null,
    projected_fold_version: u64 = 0,
    projected_intra: ?u128 = null,
    generation: u64 = 0,
    view_version: u64 = 0,
    projection_version: u64 = 0,
    parameters_version: u64 = 0,
    scale: f32 = 1,
    estimate: f32 = 20,
    bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    total_batches: u64 = 0,
    total_bytes: u64 = 0,
    fn allocator(self: *State) std.mem.Allocator {
        return self.budget.allocator();
    }
    fn intercept(self: *State, window: z.Window, input: PreInput) !HookOutcome {
        const hook = self.pre_input orelse return .pass;
        if (self.pre_input_running) return error.Busy;
        const revision = try self.document.version();
        const token = self.token;
        const space = self.native_space;
        const view_version = self.view_version;
        const projection_version = self.projection_version;
        const input_stamp = try window.textInputStamp();
        if (self.clients == std.math.maxInt(usize)) return error.CapacityExceeded;
        self.clients += 1;
        self.pre_input_running = true;
        const decision = hook.call(hook.context, window, @ptrCast(self), input);
        // No caller or allocator callback follows this withdrawal before the
        // outcome is known. The callback could not close its pinned Adapter.
        self.pre_input_running = false;
        self.clients -= 1;
        if (window.isClosed() or window.app.phase == .stopping or window.app.phase == .stopped or !std.meta.eql(input_stamp, window.textInputStamp() catch return .superseded) or !std.meta.eql(token, self.token) or !std.meta.eql(space, self.native_space) or view_version != self.view_version or projection_version != self.projection_version or revision != try self.document.version()) return .superseded;
        self.checkNativeInput() catch return .superseded;
        return if (decision == .consume) .rejected else .pass;
    }
    /// The hook already owns the input outcome. Presentation failures are
    /// retained for explicit preparation, never returned as a retryable input.
    fn presentIntercepted(self: *State, window: z.Window, bounds: Rect, parameters: Parameters) void {
        self.checkNativeInput() catch return;
        self.busy = true;
        defer self.busy = false;
        if (self.token == null) {
            _ = prepareView(self, bounds, parameters) catch |err| {
                self.layout_required = true;
                self.last_layout_error = self.budget.normalize(err);
                return;
            };
            window.invalidate();
            return;
        }
        updateAfterInput(self, window, bounds, parameters) catch |err| {
            self.layout_required = true;
            if (err != error.LayoutRequired) self.last_layout_error = self.budget.normalize(err);
        };
    }
    fn nativeAuthority(self: *State, window: z.Window) !?u64 {
        const observer = self.native_observer orelse return null;
        const validate = observer.validate orelse return null;
        const was_busy = self.busy;
        self.busy = true;
        defer self.busy = was_busy;
        return try validate(observer.context, window, @ptrCast(self), self.native_space);
    }
    fn captureNativeInput(self: *State, window: z.Window) !NativeInput {
        var input: NativeInput = .{ .window = window, .token = self.token, .space = self.native_space, .space_generation = 0, .input_stamp = try window.textInputStamp(), .observer_generation = self.observer_generation, .authority = null };
        // Capture the original front before foreign validation, while leaving
        // the presentation owner's rejection ahead of a missing Space error.
        const generation: anyerror!u64 = if (input.space) |space| if (space.resolve()) |token| token.generation else |err| err else 0;
        input.authority = try self.nativeAuthority(window);
        input.space_generation = try generation;
        try self.checkInputIdentity(input);
        return input;
    }
    fn checkInputIdentity(self: *State, input: NativeInput) !void {
        if (input.window.app.phase == .stopping or input.window.app.phase == .stopped or input.window.isClosed()) return error.Closed;
        if (!std.meta.eql(input.input_stamp, try input.window.textInputStamp())) return error.StaleTextInput;
        if (!std.meta.eql(input.token, self.token)) return error.StaleTextClient;
        if (input.token != null and !std.meta.eql(input.token, input.window.textClientToken())) return error.StaleTextClient;
        if (!std.meta.eql(input.space, self.native_space)) return error.StaleSpace;
        if (input.observer_generation != self.observer_generation) return error.StalePresentation;
        if (input.space) |binding| {
            if (!std.meta.eql(binding.window, input.window)) return error.ForeignWindow;
            if ((try binding.resolve()).generation != input.space_generation) return error.StaleSpace;
        }
    }
    fn checkInput(self: *State, input: NativeInput) !void {
        try self.checkInputIdentity(input);
        if (input.authority != try self.nativeAuthority(input.window)) return error.StalePresentation;
        // A validator may synchronously retire the window or binding.
        try self.checkInputIdentity(input);
    }
    fn checkNativeInput(self: *State) !void {
        if (self.native_input) |input| try self.checkInput(input);
    }
    fn validateNativeCommit(ptr: *anyopaque) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        try self.checkNativeInput();
        if (self.owner_command) |command| try command.validateCommit();
        if (self.pointer_owner) |owner| {
            if (owner.input != null) try pointerValidateCommit(self, owner);
        }
    }
    fn mutate(self: *State, comptime operation: anytype, arguments: anytype) @typeInfo(@TypeOf(operation)).@"fn".return_type.? {
        if (self.owner_command) |command| try command.beforeMutation(self.document);
        if (self.pointer_owner) |owner| if (owner.input != null) {
            try pointerBeforeMutation(self, owner);
        };
        const guard = if (self.native_input != null or self.owner_command != null) try self.document.beginCommitGuard(.{ .context = self, .validate = validateNativeCommit }) else null;
        defer if (guard) |scope| scope.end();
        const result = try @call(.auto, operation, arguments);
        if (self.owner_command) |command| command.record(self.document);
        if (self.pointer_owner) |owner| {
            if (owner.input) |*input| input.revision = try self.document.version();
        }
        return result;
    }
    fn currentIndex(self: *State) !*ix.Node {
        if (self.index_required) return error.IndexRequired;
        if (self.folds_required or self.pending_fold_restore) return error.FoldIndexRequired;
        return self.overlay orelse self.committed.?;
    }
    fn receipt(self: *State, at: usize) *Receipt {
        return &self.history[(self.history_start + at) % self.history.len];
    }
    fn drop(self: *State, value: Receipt) void {
        ix.release(&self.storage, value.before);
        ix.release(&self.storage, value.after);
        folding.release(value.before_folds);
        folding.release(value.after_folds);
    }
    fn clearHistory(self: *State) void {
        for (0..self.history_len) |i| self.drop(self.receipt(i).*);
        self.history_start = 0;
        self.history_len = 0;
        self.history_cursor = 0;
    }
    fn note(self: *State, before: *ix.Node, after: *ix.Node, after_folds: ?*folding.Set) void {
        if (self.history.len == 0) return;
        const value: Receipt = .{ .before = ix.retain(before).?, .after = ix.retain(after).?, .before_folds = folding.retain(self.folds), .after_folds = folding.retain(after_folds) };
        while (self.history_len > self.history_cursor) {
            self.history_len -= 1;
            self.drop(self.receipt(self.history_len).*);
        }
        if (self.history_len == self.history.len) {
            self.drop(self.receipt(0).*);
            self.history_start = (self.history_start + 1) % self.history.len;
            self.history_len -= 1;
            self.history_cursor -= 1;
        }
        self.receipt(self.history_len).* = value;
        self.history_len += 1;
        self.history_cursor = self.history_len;
    }
    fn synchronize(self: *State) !void {
        if (try self.document.version() != self.observed) {
            self.index_required = true;
            self.layout_required = true;
            self.clearHistory();
            self.folds_required = self.folds_required or folding.count(self.folds) != 0 or self.pending_fold_restore;
            folding.release(self.pending_folds);
            self.pending_folds = null;
            self.pending_fold_restore = false;
            return error.IndexRequired;
        }
        if (self.index_required) return error.IndexRequired;
        if (self.folds_required or self.pending_fold_restore) return error.FoldIndexRequired;
    }
    fn reindex(self: *State) !void {
        var builder: ix.Builder = .{ .storage = &self.storage, .row_limit = self.limits.paragraphs, .next_id = self.next_id, .epoch = self.next_epoch, .estimate = try ix.quantize(self.estimate) };
        defer builder.deinit();
        if (self.next_epoch == std.math.maxInt(u64)) return error.IdExhausted;
        const candidate = try builder.finish(self.document);
        errdefer ix.release(&self.storage, candidate);
        var overlay: ?ix.Edit = null;
        if (try self.document.composition()) |composition| overlay = try ix.plan(&self.storage, candidate, composition.range, composition.text, builder.next_id, self.next_epoch, try ix.quantize(self.estimate), self.limits.paragraphs);
        ix.release(&self.storage, self.committed);
        ix.release(&self.storage, self.overlay);
        folding.release(self.overlay_folds);
        self.overlay_folds = null;
        self.committed = candidate;
        self.folds_required = self.folds_required or folding.count(self.folds) != 0 or self.pending_fold_restore;
        folding.release(self.pending_folds);
        self.pending_folds = null;
        self.pending_fold_restore = false;
        self.overlay = if (overlay) |value| value.root else null;
        self.next_id = if (overlay) |value| value.next_id else builder.next_id;
        self.next_epoch += 1;
        self.observed = try self.document.version();
        self.index_required = false;
        self.layout_required = true;
        self.clearHistory();
        const root = self.overlay orelse self.committed.?;
        self.anchor.line = @min(self.anchor.line, root.sum.rows - 1);
        self.anchor.id = ix.get(&self.storage, root, self.anchor.line).id;
        self.anchor.intra = 0;
    }
    fn normalizeAnchor(self: *State) void {
        const root = self.overlay orelse self.committed.?;
        self.anchor.line = @min(self.anchor.line, root.sum.rows - 1);
        if (ix.get(&self.storage, root, self.anchor.line).hidden) {
            self.anchor.line = ix.previousVisible(&self.storage, root, self.anchor.line) orelse ix.nextVisible(&self.storage, root, self.anchor.line).?;
            self.anchor.intra = 0;
        }
        self.anchor.id = ix.get(&self.storage, root, self.anchor.line).id;
    }
    fn restoreFolds(self: *State) !void {
        if (!self.pending_fold_restore) return;
        if (self.fold_version == std.math.maxInt(u64)) return error.IdExhausted;
        const candidate = if (self.fold_owner != null) null else try folding.merge(self.allocator(), &self.storage, self.committed.?, self.pending_folds, self.folds, self.limits.folds);
        errdefer folding.release(candidate);
        const root = if (self.fold_owner != null) try ix.setHidden(&self.storage, self.committed.?, 0, self.committed.?.sum.rows, false) else try folding.apply(&self.storage, self.committed.?, self.pending_folds, candidate);
        errdefer ix.release(&self.storage, root);
        if (try self.document.version() != self.observed) {
            try self.synchronize();
            unreachable;
        }
        ix.release(&self.storage, self.committed);
        self.committed = root;
        folding.release(self.folds);
        self.folds = candidate;
        folding.release(self.pending_folds);
        self.pending_folds = null;
        self.pending_fold_restore = false;
        self.fold_version += 1;
    }
    fn editFolds(self: *State, candidate: **ix.Node, edits: []const d.Replacement) !?*folding.Set {
        // A borrowed derived layer is stamped to committed text, not mapped
        // speculatively through edits or composition overlays. Lazy show-all
        // keeps this incremental; invalidation does not rescan the document.
        const mapped = if (self.fold_owner != null) null else try folding.mapped(self.allocator(), &self.storage, self.committed.?, candidate.*, self.folds, edits, self.limits.folds);
        errdefer folding.release(mapped);
        if (self.folds != null) {
            if (self.fold_version == std.math.maxInt(u64)) return error.IdExhausted;
            const visible = try ix.setHidden(&self.storage, candidate.*, 0, candidate.*.sum.rows, false);
            defer ix.release(&self.storage, visible);
            const hidden = try folding.apply(&self.storage, visible, null, mapped);
            ix.release(&self.storage, candidate.*);
            candidate.* = hidden;
        }
        return mapped;
    }
    fn publishFolds(self: *State, candidate: ?*folding.Set) void {
        if (self.folds != null or candidate != null) self.fold_version += 1;
        folding.release(self.folds);
        self.folds = candidate;
    }
    fn validateRange(self: *State, range: d.Range) !void {
        if (range.start > range.end) return error.InvalidRange;
        _ = try self.document.utf16Offset(range.start);
        _ = try self.document.utf16Offset(range.end);
    }
    fn mappedAnchor(self: *State, anchor: Anchor, root: *ix.Node, first: usize, removed: usize, inserted: usize) Anchor {
        var result = anchor;
        if (result.line >= first + removed) {
            result.line = result.line - removed + inserted;
        } else if (result.line >= first) {
            result.line = first;
            result.intra = 0;
        }
        result.line = @min(result.line, root.sum.rows - 1);
        result.id = ix.get(&self.storage, root, result.line).id;
        return result;
    }
    fn committedAnchor(self: *State) !Anchor {
        const overlay = self.overlay orelse return self.anchor;
        const marked = (try self.document.composition()).?;
        const root = self.committed.?;
        const first = ix.lineAt(&self.storage, root, marked.range.start);
        const removed = ix.lineAt(&self.storage, root, marked.range.end) - first + 1;
        const inserted = overlay.sum.rows - (root.sum.rows - removed);
        return self.mappedAnchor(self.anchor, root, first, inserted, removed);
    }
    fn replace(self: *State, range: d.Range, text: []const u8, commit: bool) !EditResult {
        try self.synchronize();
        try self.validateRange(range);
        if (text.len > 1024 * 1024 * 1024) return error.CapacityExceeded;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
        if (self.next_epoch == std.math.maxInt(u64)) return error.IdExhausted;
        if (!commit and try self.document.composition() != null) return error.CompositionActive;
        const base_anchor = try self.committedAnchor();
        var plan = try ix.plan(&self.storage, self.committed.?, range, text, self.next_id, self.next_epoch, try ix.quantize(self.estimate), self.limits.paragraphs);
        errdefer ix.release(&self.storage, plan.root);
        const next_folds = try self.editFolds(&plan.root, &.{.{ .range = range, .text = text }});
        errdefer folding.release(next_folds);
        try self.synchronize();
        try self.checkNativeInput();
        if (commit) try self.mutate(d.Document.commitComposition, .{ self.document, text }) else try self.mutate(d.Document.replace, .{ self.document, range, text });
        const committed_revision = try self.document.version();
        self.note(self.committed.?, plan.root, next_folds);
        self.publishFolds(next_folds);
        ix.release(&self.storage, self.committed);
        ix.release(&self.storage, self.overlay);
        folding.release(self.overlay_folds);
        self.overlay_folds = null;
        self.committed = plan.root;
        self.overlay = null;
        self.next_id = plan.next_id;
        self.next_epoch += 1;
        self.observed = committed_revision;
        self.anchor = self.mappedAnchor(base_anchor, plan.root, plan.first, plan.removed, plan.inserted);
        self.affinity = .downstream;
        self.preferred_x = null;
        self.visual_count = 0;
        self.layout_required = true;
        self.reveal = true;
        const invalidated = try self.document.version() != committed_revision;
        if (invalidated) self.index_required = true;
        return .{ .changed = true, .index_required = invalidated };
    }
    fn replaceMany(self: *State, edits: []const d.Replacement, mode: BatchMode, text: []const u8) !EditResult {
        return self.replaceManySelected(edits, mode, text, null, null);
    }
    fn replaceManySelected(self: *State, edits: []const d.Replacement, mode: BatchMode, text: []const u8, final: ?d.SelectionList, expected_revision: ?u64) !EditResult {
        try self.synchronize();
        if (edits.len == 0) return .{ .changed = false, .index_required = false };
        if (edits.len > self.limits.batch_edits) return error.CapacityExceeded;
        var previous: ?d.Range = null;
        for (edits) |edit| {
            try self.validateRange(edit.range);
            if (!std.unicode.utf8ValidateSlice(edit.text)) return error.InvalidUtf8;
            if (std.mem.indexOfScalar(u8, edit.text, 0) != null) return error.EmbeddedNul;
            if (previous) |before| if (edit.range.start <= before.start or edit.range.start < before.end or (edit.range.start == before.end and (edit.range.start == edit.range.end or before.start == before.end))) return error.OverlappingEdits;
            previous = edit.range;
        }
        if (self.next_epoch == std.math.maxInt(u64)) return error.IdExhausted;
        var candidate = ix.retain(self.committed).?;
        errdefer ix.release(&self.storage, candidate);
        var anchor = try self.committedAnchor();
        var next_id = self.next_id;
        var at = edits.len;
        while (at != 0) {
            at -= 1;
            const plan = try ix.plan(&self.storage, candidate, edits[at].range, edits[at].text, next_id, self.next_epoch, try ix.quantize(self.estimate), self.limits.paragraphs);
            ix.release(&self.storage, candidate);
            candidate = plan.root;
            next_id = plan.next_id;
            anchor = self.mappedAnchor(anchor, candidate, plan.first, plan.removed, plan.inserted);
        }
        const next_folds = try self.editFolds(&candidate, edits);
        errdefer folding.release(next_folds);
        if (expected_revision) |revision| if (try self.document.version() != revision) return error.StaleRevision;
        if (final) |selected| {
            for (selected.items) |item| if (item.range().end > candidate.sum.bytes) return error.InvalidRange;
            try self.validateFoldCaretsIn(candidate, selected.items);
        }
        try self.synchronize();
        try self.checkNativeInput();
        switch (mode) {
            .mapped => if (final) |selected| try self.mutate(d.Document.replaceManyWithSelections, .{ self.document, expected_revision.?, edits, selected.items, selected.primary }) else try self.mutate(d.Document.replaceMany, .{ self.document, self.observed, edits }),
            .selections => try self.mutate(d.Document.replaceSelections, .{ self.document, text }),
            .composition => try self.mutate(d.Document.commitComposition, .{ self.document, text }),
        }
        const committed_revision = try self.document.version();
        self.note(self.committed.?, candidate, next_folds);
        self.publishFolds(next_folds);
        ix.release(&self.storage, self.committed);
        ix.release(&self.storage, self.overlay);
        folding.release(self.overlay_folds);
        self.overlay_folds = null;
        self.committed = candidate;
        self.overlay = null;
        self.anchor = anchor;
        self.next_id = next_id;
        self.next_epoch += 1;
        self.observed = committed_revision;
        self.layout_required = true;
        self.reveal = true;
        self.affinity = .downstream;
        self.preferred_x = null;
        self.visual_count = 0;
        const invalidated = try self.document.version() != committed_revision;
        if (invalidated) self.index_required = true;
        return .{ .changed = true, .index_required = invalidated };
    }
    fn replaceSelections(self: *State, text: []const u8, commit: bool) !EditResult {
        try self.synchronize();
        const selected = try self.document.selections(self.selection_buffer);
        if (selected.items.len == 1) return self.replace(selected.items[0].range(), text, commit);
        const edits = try self.allocator().alloc(d.Replacement, selected.items.len);
        defer self.allocator().free(edits);
        for (edits, selected.items) |*edit, item| edit.* = .{ .range = item.range(), .text = text };
        return self.replaceMany(edits, if (commit) .composition else .selections, text);
    }
    fn allSelections(self: *State) !d.SelectionList {
        const selected = try self.document.selections(self.selection_buffer);
        if (try self.document.composition()) |marked| {
            for (self.selection_buffer[0..selected.items.len], 0..) |*item, at| {
                if (at == selected.primary) {
                    item.* = .{ .anchor = marked.range.start + marked.selection.anchor, .caret = marked.range.start + marked.selection.caret };
                } else {
                    if (item.anchor >= marked.range.end) item.anchor = item.anchor - (marked.range.end - marked.range.start) + marked.text.len;
                    if (item.caret >= marked.range.end) item.caret = item.caret - (marked.range.end - marked.range.start) + marked.text.len;
                }
            }
        }
        return selected;
    }
    fn affinityAt(self: *State, index: usize, primary: usize) t.Affinity {
        if (self.visual_revision == self.observed and index < self.visual_count) return self.visual[index].affinity;
        return if (index == primary) self.affinity else .downstream;
    }
    fn preferredAt(self: *State, index: usize, primary: usize) ?f32 {
        if (self.visual_revision == self.observed and index < self.visual_count) return self.visual[index].preferred_x;
        return if (index == primary) self.preferred_x else null;
    }
    fn publishMovement(self: *State, movements: []Movement, primary: usize) !void {
        const input = try self.allocator().alloc(d.Selection, movements.len);
        defer self.allocator().free(input);
        for (input, movements) |*selected, movement| selected.* = movement.selected;
        try self.synchronize();
        try self.validateFoldCarets(input);
        try self.checkNativeInput();
        _ = try self.mutate(d.Document.setSelections, .{ self.document, input, primary });
        self.observed = try self.document.version();
        const actual = try self.document.selections(self.selection_buffer);
        std.mem.sort(Movement, movements, {}, struct {
            fn less(_: void, a: Movement, b: Movement) bool {
                return a.selected.caret < b.selected.caret or (a.selected.caret == b.selected.caret and a.primary and !b.primary);
            }
        }.less);
        for (actual.items, 0..) |selected, at| {
            var low: usize = 0;
            var high = movements.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (movements[middle].selected.caret < selected.caret) low = middle + 1 else high = middle;
            }
            self.visual[at] = .{ .selected = selected };
            if (low < movements.len and movements[low].selected.caret == selected.caret) {
                self.visual[at].affinity = movements[low].affinity;
                self.visual[at].preferred_x = movements[low].preferred_x;
            }
        }
        self.visual_count = actual.items.len;
        self.visual_revision = self.observed;
        self.affinity = self.visual[actual.primary].affinity;
        self.preferred_x = self.visual[actual.primary].preferred_x;
        self.layout_required = true;
        self.reveal = true;
    }
    fn preedit(self: *State, text: []const u8, selected: d.Selection) !void {
        try self.synchronize();
        if (text.len > 65536) return error.CapacityExceeded;
        if (self.next_epoch == std.math.maxInt(u64)) return error.IdExhausted;
        const range = if (try self.document.composition()) |old| old.range else (try self.document.selection()).range();
        const base_anchor = try self.committedAnchor();
        var plan = try ix.plan(&self.storage, self.committed.?, range, text, self.next_id, self.next_epoch, try ix.quantize(self.estimate), self.limits.paragraphs);
        errdefer ix.release(&self.storage, plan.root);
        const overlay_folds = try self.editFolds(&plan.root, &.{.{ .range = range, .text = text }});
        errdefer folding.release(overlay_folds);
        try self.synchronize();
        try self.checkNativeInput();
        try self.mutate(d.Document.setComposition, .{ self.document, text, selected });
        ix.release(&self.storage, self.overlay);
        folding.release(self.overlay_folds);
        self.overlay_folds = null;
        self.overlay = plan.root;
        self.overlay_folds = overlay_folds;
        self.affinity = .downstream;
        self.preferred_x = null;
        self.visual_count = 0;
        self.anchor = self.mappedAnchor(base_anchor, plan.root, plan.first, plan.removed, plan.inserted);
        self.next_id = plan.next_id;
        self.next_epoch += 1;
        self.observed = try self.document.version();
        self.layout_required = true;
        self.reveal = true;
    }
    fn cancel(self: *State) !bool {
        try self.synchronize();
        const base_anchor = try self.committedAnchor();
        try self.checkNativeInput();
        if (!try self.mutate(d.Document.cancelComposition, .{self.document})) return false;
        ix.release(&self.storage, self.overlay);
        folding.release(self.overlay_folds);
        self.overlay_folds = null;
        self.overlay = null;
        self.observed = try self.document.version();
        self.layout_required = true;
        self.reveal = true;
        self.anchor = base_anchor;
        return true;
    }
    fn selection(self: *State) !d.Selection {
        if (try self.document.composition()) |value| return .{ .anchor = value.range.start + value.selection.anchor, .caret = value.range.start + value.selection.caret };
        return self.document.selection();
    }
    fn select(self: *State, selected: d.Selection, affinity: t.Affinity) !bool {
        if (self.pointer_owner) |owner| if (owner.input == null) pointerRevoke(self, owner);
        try self.synchronize();
        try self.validateFoldCarets(&.{selected});
        try self.checkNativeInput();
        const changed = try self.mutate(d.Document.setSelection, .{ self.document, selected });
        if (changed or self.affinity != affinity) {
            self.observed = try self.document.version();
            self.layout_required = true;
            self.reveal = true;
        }
        self.affinity = affinity;
        self.visual_count = 0;
        return changed;
    }
    fn validateFoldCarets(self: *State, selections: []const d.Selection) !void {
        if (self.fold_owner == null) return;
        for (selections) |selected| try self.validateRange(selected.range());
        return self.validateFoldCaretsIn(try self.currentIndex(), selections);
    }
    fn validateFoldCaretsIn(self: *State, root: *ix.Node, selections: []const d.Selection) !void {
        if (self.fold_owner == null) return;
        for (selections) |selected| {
            if (selected.range().end > root.sum.bytes) return error.InvalidRange;
            if (ix.get(&self.storage, root, ix.lineAt(&self.storage, root, selected.caret)).hidden) return error.CaretInsideFold;
        }
    }
    fn discardOwnedFolds(self: *State) bool {
        const old = self.folds;
        const pending = self.pending_folds;
        const overlay = self.overlay_folds;
        const changed = old != null or pending != null or overlay != null or self.folds_required or self.pending_fold_restore;
        self.folds = null;
        self.pending_folds = null;
        self.overlay_folds = null;
        self.folds_required = false;
        self.pending_fold_restore = false;
        if (changed) {
            // No allocation is required to revoke a derived layer during
            // close. Existing roots remain owned but cannot be queried until
            // the next explicit prepare/reindex rebuilds visible aggregates.
            self.index_required = true;
            self.layout_required = true;
            self.fold_version +|= 1;
            self.clearHistory();
        }
        folding.release(old);
        folding.release(pending);
        folding.release(overlay);
        return changed;
    }
    fn undo(self: *State, redo: bool) !EditResult {
        self.synchronize() catch |err| if (err != error.IndexRequired and err != error.FoldIndexRequired) return err;
        try self.checkNativeInput();
        const changed = if (redo) try self.mutate(d.Document.redo, .{self.document}) else try self.mutate(d.Document.undo, .{self.document});
        if (!changed) return .{ .changed = false, .index_required = self.index_required };
        self.observed = try self.document.version();
        const known = !self.index_required and (if (redo) self.history_cursor < self.history_len else self.history_cursor > 0);
        if (known) {
            const receipt_value = self.receipt(if (redo) self.history_cursor else self.history_cursor - 1).*;
            const root = ix.retain(if (redo) receipt_value.after else receipt_value.before).?;
            ix.release(&self.storage, self.committed);
            self.committed = root;
            folding.release(self.pending_folds);
            self.pending_folds = folding.retain(if (redo) receipt_value.after_folds else receipt_value.before_folds);
            self.pending_fold_restore = self.folds != null or self.pending_folds != null;
            if (redo) self.history_cursor += 1 else self.history_cursor -= 1;
            self.anchor.line = @min(self.anchor.line, root.sum.rows - 1);
            self.anchor.id = ix.get(&self.storage, root, self.anchor.line).id;
            self.anchor.intra = 0;
        } else {
            self.index_required = true;
            self.folds_required = self.folds != null or self.pending_fold_restore;
            folding.release(self.pending_folds);
            self.pending_folds = null;
            self.pending_fold_restore = false;
            self.clearHistory();
        }
        ix.release(&self.storage, self.overlay);
        folding.release(self.overlay_folds);
        self.overlay_folds = null;
        self.overlay = null;
        self.layout_required = true;
        self.reveal = true;
        return .{ .changed = true, .index_required = self.index_required };
    }
    fn runOwnerCommand(self: *State, command: Command) !EditResult {
        return switch (command) {
            .undo => self.undo(false),
            .redo => self.undo(true),
            .replace_selections => |text| self.replaceSelections(text, false),
            .select_all => .{ .changed = try self.select(.{ .anchor = 0, .caret = try self.document.byteLength() }, .downstream), .index_required = self.index_required },
            .set_selection => |selected| .{ .changed = try self.select(selected, .downstream), .index_required = self.index_required },
        };
    }
    fn readDisplay(self: *State, range: d.Range, bytes: []u8) !void {
        try self.readShown(range, bytes);
        if (self.masked) password_mask.apply(bytes);
    }
    fn readShown(self: *State, range: d.Range, bytes: []u8) !void {
        const composition_value = try self.document.composition();
        if (composition_value == null) {
            _ = try self.document.read(range, bytes);
            return;
        }
        const marked = composition_value.?;
        const end = marked.range.start + marked.text.len;
        var at = range.start;
        var filled: usize = 0;
        if (at < marked.range.start) {
            const count = @min(range.end, marked.range.start) - at;
            _ = try self.document.read(.{ .start = at, .end = at + count }, bytes[0..count]);
            at += count;
            filled += count;
        }
        if (at < range.end and at < end) {
            const count = @min(range.end, end) - at;
            @memcpy(bytes[filled..][0..count], marked.text[at - marked.range.start ..][0..count]);
            at += count;
            filled += count;
        }
        if (at < range.end) _ = try self.document.read(.{ .start = marked.range.end + at - end, .end = marked.range.end + range.end - end }, bytes[filled..]);
    }
};

const RangeMarkerGuard = struct {
    state: *State,
    window: ?z.Window,
    token: ?z.TextClientToken,
    text_version: u64,
    fn check(self: RangeMarkerGuard) !void {
        if (self.window) |window| if (window.isClosed() or window.app.phase == .stopping or window.app.phase == .stopped) return error.Closed;
        if (!std.meta.eql(self.token, self.state.token)) return error.StaleTextClient;
        if (try self.state.document.committedTextVersion() != self.text_version) return error.StaleRevision;
        if (try self.state.document.composition() != null) return error.CompositionActive;
    }
};

/// Owning visible-paragraph adapter. Document is the sole mutable text/undo
/// authority. Document, Engine and their allocators outlive this adapter.
pub const Adapter = opaque {
    fn state(self: *const Adapter) !*State {
        const value: *State = @ptrCast(@alignCast(@constCast(self)));
        if (std.Thread.getCurrentId() != value.owner) return error.WrongThread;
        if (value.busy) return error.Busy;
        return value;
    }
    pub fn create(allocator: std.mem.Allocator, document: *d.Document, engine: *t.Engine, limits: Limits) !*Adapter {
        // The mutable local has a distinct address across allocator reentry;
        // passing another immutable aggregate could still alias the caller.
        var captured = limits;
        return createCaptured(allocator, document, engine, &captured);
    }
    noinline fn createCaptured(allocator: std.mem.Allocator, document: *d.Document, engine: *t.Engine, limits: *Limits) !*Adapter {
        _ = try engine.lastNativeError();
        if (limits.paragraphs == 0 or limits.paragraphs > 1000000 or limits.nodes == 0 or limits.nodes > 4194304 or limits.bytes < @sizeOf(State) + @sizeOf(memory.Budget) or limits.bytes > 1024 * 1024 * 1024 or limits.batches == 0 or limits.batches > max_batches or limits.batch_rows == 0 or limits.batch_rows > cache.max_rows or limits.batch_bytes == 0 or limits.paragraph_bytes < limits.batch_bytes or limits.paragraph_bytes > 65536 or limits.shaped_bytes < limits.paragraph_bytes or limits.visual_stops < 2 or limits.visual_stops > 16386 or limits.rectangles > 16384 or limits.caret_work > 64 * 1024 * 1024 or limits.metadata_history > 4096 or limits.selections == 0 or limits.selections > 4096 or limits.batch_edits == 0 or limits.batch_edits > 65536 or limits.folds > 65536) return error.InvalidLimits;
        if (limits.prepared.pixels == 0 or limits.prepared.pixels > 16 * 1024 * 1024 or limits.prepared.bytes == 0 or limits.prepared.bytes > 64 * 1024 * 1024 or limits.line_backgrounds > 65536 or limits.range_markers > 65536 or limits.range_marker_work > 64 * 1024 * 1024) return error.InvalidLimits;
        try document.retainClient();
        errdefer document.releaseClient() catch unreachable;
        const budget = try allocator.create(memory.Budget);
        errdefer allocator.destroy(budget);
        budget.* = .{ .source = allocator, .limit = limits.bytes, .live = @sizeOf(memory.Budget), .peak = @sizeOf(memory.Budget) };
        const value = budget.allocator().create(State) catch |err| return budget.normalize(err);
        errdefer budget.allocator().destroy(value);
        const history = budget.allocator().alloc(Receipt, limits.metadata_history) catch |err| return budget.normalize(err);
        errdefer budget.allocator().free(history);
        const selection_buffer = budget.allocator().alloc(d.Selection, limits.selections) catch |err| return budget.normalize(err);
        errdefer budget.allocator().free(selection_buffer);
        const visual = budget.allocator().alloc(VisualCaret, limits.selections) catch |err| return budget.normalize(err);
        errdefer budget.allocator().free(visual);
        value.* = .{ .budget = budget, .owner = std.Thread.getCurrentId(), .document = document, .engine = engine, .limits = limits.*, .storage = .{ .allocator = budget.allocator(), .node_limit = limits.nodes }, .observed = try document.version(), .history = history, .selection_buffer = selection_buffer, .visual = visual };
        value.reindex() catch |err| return budget.normalize(err);
        return @ptrCast(value);
    }
    pub fn close(self: *Adapter) !void {
        const value = try self.state();
        if (value.fold_owner != null) return error.FoldOwnerAttached;
        if (value.native_observer != null) return error.ObserverAttached;
        if (value.clients != 0) return error.ClientsAlive;
        if (value.token != null) return error.ClientAttached;
        if (value.view) |*view| try view.ensureUnused();
        value.busy = true;
        value.pre_input = null;
        if (value.pointer_owner) |owner| value.allocator().destroy(owner);
        if (value.view) |*view| view.close(value.allocator());
        if (value.projected_geometry) |*geometry_value| geometry_value.close(&value.storage);
        if (value.projected_plan) |plan| plan.releaseClient();
        for (value.entries[0..value.entry_count]) |entry| entry.?.release();
        value.clearHistory();
        folding.release(value.folds);
        folding.release(value.pending_folds);
        ix.release(&value.storage, value.committed);
        ix.release(&value.storage, value.overlay);
        folding.release(value.overlay_folds);
        const budget = value.budget;
        value.allocator().free(value.history);
        value.allocator().free(value.selection_buffer);
        value.allocator().free(value.visual);
        value.allocator().free(value.line_backgrounds);
        value.allocator().free(value.range_markers);
        value.document.releaseClient() catch unreachable;
        value.allocator().destroy(value);
        std.debug.assert(budget.live == @sizeOf(memory.Budget) and budget.external == 0);
        budget.source.destroy(budget);
    }
    pub fn replace(self: *Adapter, range: d.Range, text: []const u8) !EditResult {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        return value.replace(range, text, false) catch |err| return value.budget.normalize(err);
    }
    pub fn replaceSelections(self: *Adapter, text: []const u8) !EditResult {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        return value.replaceSelections(text, false) catch |err| return value.budget.normalize(err);
    }
    pub fn replaceMany(self: *Adapter, expected_revision: u64, edits: []const d.Replacement) !EditResult {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        if (try value.document.version() != expected_revision) return error.StaleRevision;
        return value.replaceMany(edits, .mapped, "") catch |err| return value.budget.normalize(err);
    }
    /// One text/index/selection transaction. Final selections use resulting
    /// UTF-8 byte positions. Once changed=true, later invalidation never means
    /// this edit should be submitted again.
    pub fn replaceManyWithSelections(self: *Adapter, expected_revision: u64, edits: []const d.Replacement, final_selections: []const d.Selection, primary: usize) !EditResult {
        const value = try self.state();
        if (try value.document.version() != expected_revision) return error.StaleRevision;
        if (edits.len == 0) return error.EmptyEdits;
        if (final_selections.len == 0 or primary >= final_selections.len) return error.InvalidSelections;
        if (final_selections.len > value.selection_buffer.len) return error.SelectionCapacityExceeded;
        value.busy = true;
        defer value.busy = false;
        return value.replaceManySelected(edits, .mapped, "", .{ .items = final_selections, .primary = primary }, expected_revision) catch |err| return value.budget.normalize(err);
    }
    pub fn setSelections(self: *Adapter, selected: []const d.Selection, primary: usize) !bool {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        try value.synchronize();
        if (selected.len > value.selection_buffer.len) return error.SelectionCapacityExceeded;
        try value.validateFoldCarets(selected);
        const changed = try value.document.setSelections(selected, primary);
        value.observed = try value.document.version();
        if (changed) {
            value.layout_required = true;
            value.reveal = true;
            value.affinity = .downstream;
            value.preferred_x = null;
        }
        return changed;
    }
    pub fn setSelection(self: *Adapter, selected: d.Selection, affinity: t.Affinity) !bool {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        return value.select(selected, affinity);
    }
    pub fn undo(self: *Adapter) !EditResult {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        return value.undo(false);
    }
    pub fn redo(self: *Adapter) !EditResult {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        return value.undo(true);
    }
    /// Caller scratch is exclusive through return and needs two entries for
    /// each current canonical selection. No per-command scratch allocation.
    /// The owner gate composes with an already active NativeInputScope using
    /// one final Document guard, and is removed before this function returns.
    pub fn runCommand(self: *Adapter, command: Command, gate: CommandGate, selection_scratch: []d.Selection) !CommandOutcome {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        var capture = try owner_commands.Capture.init(value.document, gate, selection_scratch);
        try capture.beforeMutation(value.document);
        value.owner_command = &capture;
        defer value.owner_command = null;
        var post_commit_error: ?anyerror = null;
        const result = value.runOwnerCommand(command) catch |err| blk: {
            if (capture.committed_revision == null) {
                // Candidate cleanup may call foreign allocators even on
                // failure. Report a revoked owner/stamp before an index error.
                try value.checkNativeInput();
                try capture.beforeMutation(value.document);
                return value.budget.normalize(err);
            }
            post_commit_error = value.budget.normalize(err);
            break :blk EditResult{ .changed = true, .index_required = true };
        };
        // This pure getter cannot call foreign code. The Adapter's client pin
        // retains Document and its owner thread through this entire operation.
        const revision = value.document.version() catch unreachable;
        var outcome = capture.outcome(revision, result.index_required or value.index_required);
        outcome.post_commit_error = post_commit_error;
        if (outcome.index_required) {
            value.index_required = true;
            value.layout_required = true;
        }
        State.validateNativeCommit(value) catch |err| {
            if (capture.committed_revision == null) return err;
            outcome.stale_after_commit = true;
            outcome.post_commit_error = outcome.post_commit_error orelse err;
        };
        return outcome;
    }
    pub fn reindex(self: *Adapter) !void {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        value.index_required = true;
        value.layout_required = true;
        value.reindex() catch |err| return value.budget.normalize(err);
    }
    /// Complete paragraph ranges in the current Document byte coordinates.
    /// Definitions are copied; an empty list explicitly clears stale folds.
    pub fn setFolds(self: *Adapter, expected_revision: u64, definitions: []const Fold) !void {
        const value = try self.state();
        if (value.fold_owner != null) return error.FoldOwnerConflict;
        value.busy = true;
        defer value.busy = false;
        if (try value.document.version() != expected_revision) return error.StaleRevision;
        if (try value.document.composition() != null) return error.CompositionActive;
        value.synchronize() catch |err| if (err != error.IndexRequired and err != error.FoldIndexRequired) return err;
        if (value.index_required) value.reindex() catch |err| return value.budget.normalize(err);
        if (value.fold_version == std.math.maxInt(u64)) return error.IdExhausted;
        const candidate = folding.create(value.allocator(), &value.storage, value.committed.?, definitions, value.limits.folds) catch |err| return value.budget.normalize(err);
        errdefer folding.release(candidate);
        if (try value.document.version() != expected_revision) return error.StaleRevision;
        const selected = try value.document.selections(value.selection_buffer);
        if (candidate) |set| for (selected.items) |item| if (set.hidden(ix.lineAt(&value.storage, value.committed.?, item.caret))) return error.CaretInsideFold;
        const root = folding.apply(&value.storage, value.committed.?, if (value.folds_required) null else if (value.pending_fold_restore) value.pending_folds else value.folds, candidate) catch |err| return value.budget.normalize(err);
        errdefer ix.release(&value.storage, root);
        if (try value.document.version() != expected_revision) return error.StaleRevision;
        ix.release(&value.storage, value.committed);
        value.committed = root;
        folding.release(value.folds);
        value.folds = candidate;
        folding.release(value.pending_folds);
        value.pending_folds = null;
        value.pending_fold_restore = false;
        value.folds_required = false;
        value.fold_version += 1;
        value.layout_required = true;
        value.normalizeAnchor();
    }
    /// Replace the complete versioned background set. Coordinates are committed
    /// Document paragraph starts; selection-only changes preserve this stamp.
    /// Text edits invalidate the set and IME preview temporarily suppresses it.
    pub fn setLineBackgrounds(self: *Adapter, expected_text_version: u64, definitions: []const LineBackground) !LineBackgroundResult {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        if (try value.document.committedTextVersion() != expected_text_version) return error.StaleRevision;
        if (try value.document.composition() != null) return error.CompositionActive;
        try line_backgrounds.validate(definitions, value.limits.line_backgrounds);
        const candidate = value.allocator().dupe(LineBackground, definitions) catch |err| return value.budget.normalize(err);
        var published = false;
        errdefer if (!published) value.allocator().free(candidate);
        // The caller allocator can reenter Document before returning storage.
        if (try value.document.committedTextVersion() != expected_text_version) return error.StaleRevision;
        if (try value.document.composition() != null) return error.CompositionActive;
        try line_backgrounds.validate(candidate, value.limits.line_backgrounds);
        for (candidate) |item| {
            const line = try value.document.lineAt(item.paragraph);
            if ((try value.document.line(line)).start != item.paragraph) return error.InvalidLineBackground;
        }
        const old = value.line_backgrounds;
        value.line_backgrounds = candidate;
        value.background_text_version = expected_text_version;
        value.layout_required = true;
        published = true;
        value.allocator().free(old);
        // Metadata publication is complete. Do not return a retryable error
        // after a foreign free changed the sole text authority.
        return .{ .current = (value.document.committedTextVersion() catch return .{ .current = false }) == expected_text_version and (value.document.composition() catch return .{ .current = false }) == null };
    }
    /// Copy only currently visible prepared paragraph rectangles in layout DIP.
    /// No rectangles are manufactured for hidden folds or stale metadata.
    pub fn preparedLineBackgrounds(self: *Adapter, bounds: Rect, destination: []LineBackgroundMark) ![]const LineBackgroundMark {
        const value = try self.state();
        const view = try ready(value, bounds, value.scale);
        if (destination.len < view.line_backgrounds.len) return error.BufferTooSmall;
        @memcpy(destination[0..view.line_backgrounds.len], view.line_backgrounds);
        return destination[0..view.line_backgrounds.len];
    }
    /// Replace paint-only committed source ranges. Selection changes preserve
    /// the text stamp. A completed publication returns its metadata version,
    /// even if foreign old-storage disposal invalidates its current authority.
    pub fn setRangeMarkers(self: *Adapter, expected_text_version: u64, definitions: []const RangeMarker) !RangeMarkerResult {
        const value = try self.state();
        const window: ?z.Window = if (value.token) |token| token.window else if (value.native_input) |input| input.window else null;
        const scope = if (window) |bound| bound.beginCallback() orelse return error.Closed else null;
        defer if (scope) |pin| pin.end();
        value.busy = true;
        defer value.busy = false;
        const guard: RangeMarkerGuard = .{ .state = value, .window = window, .token = value.token, .text_version = expected_text_version };
        try guard.check();
        if (value.range_marker_version == std.math.maxInt(u64)) return error.IdExhausted;
        try range_markers.validate(definitions, value.limits.range_markers);
        const candidate = range_markers.capture(value.allocator(), definitions) catch |err| return value.budget.normalize(err);
        var published = false;
        errdefer if (!published) value.allocator().free(candidate);
        try guard.check();
        try range_markers.validateOwned(candidate, value.limits.range_markers);
        for (candidate) |entry| try value.validateRange(entry.marker.range);
        const old = value.range_markers;
        value.range_markers = candidate;
        value.marker_text_version = expected_text_version;
        value.range_marker_version += 1;
        const version = value.range_marker_version;
        value.layout_required = true;
        published = true;
        value.allocator().free(old);
        guard.check() catch return .{ .version = version, .current = false };
        return .{ .version = version, .current = true };
    }
    /// Copy the current prepared decorations in layout DIP. Metadata, text,
    /// view and projection identities are explicit; marker indices identify
    /// only this complete metadata version, never a persistent text anchor.
    pub fn preparedRangeMarkers(self: *Adapter, bounds: Rect, destination: []RangeMarkerMark) !PreparedRangeMarkers {
        const value = try self.state();
        const view = try ready(value, bounds, value.scale);
        if (view.range_marker_version != value.range_marker_version) return error.LayoutRequired;
        if (destination.len < view.range_markers.len) return error.BufferTooSmall;
        @memcpy(destination[0..view.range_markers.len], view.range_markers);
        return .{ .items = destination[0..view.range_markers.len], .version = view.range_marker_version, .text_version = view.text_version, .view_version = value.view_version, .projection_version = value.projection_version };
    }
    pub fn setFoldCollapsed(self: *Adapter, id: u64, collapsed: bool) !bool {
        const value = try self.state();
        if (value.fold_owner != null) return error.FoldOwnerConflict;
        value.busy = true;
        defer value.busy = false;
        try value.synchronize();
        if (try value.document.composition() != null) return error.CompositionActive;
        const set = value.folds orelse return error.FoldNotFound;
        const at = set.find(id) orelse return error.FoldNotFound;
        if (set.entries[at].fold.collapsed == collapsed) return false;
        if (value.fold_version == std.math.maxInt(u64)) return error.IdExhausted;
        const selected = try value.document.selections(value.selection_buffer);
        const candidate = folding.changed(value.allocator(), &value.storage, value.committed.?, set, id, collapsed, selected.items, value.limits.folds) catch |err| return value.budget.normalize(err);
        errdefer folding.release(candidate);
        const root = folding.apply(&value.storage, value.committed.?, set, candidate) catch |err| return value.budget.normalize(err);
        errdefer ix.release(&value.storage, root);
        try value.synchronize();
        ix.release(&value.storage, value.committed);
        value.committed = root;
        folding.release(value.folds);
        value.folds = candidate;
        value.fold_version += 1;
        value.layout_required = true;
        value.normalizeAnchor();
        return true;
    }
    /// Borrow the single fold authority only while it is empty. The token is
    /// checked while Adapter lives; it is not safe after Adapter.close.
    pub fn reserveFolds(self: *Adapter) !FoldToken {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        try value.synchronize();
        if (value.fold_owner != null or value.folds != null or value.pending_folds != null or value.overlay_folds != null) return error.FoldOwnerConflict;
        if (try value.document.composition() != null) return error.CompositionActive;
        if (value.fold_generation == std.math.maxInt(u64)) return error.IdExhausted;
        value.fold_generation += 1;
        value.fold_owner = value.fold_generation;
        return .{ .adapter = self, .generation = value.fold_generation };
    }
    /// Infallible-allocation revocation. A nonempty discarded layer makes the
    /// index explicitly stale; its native resources remain independently owned.
    pub fn clearOwnedFolds(self: *Adapter, token: FoldToken) !bool {
        const value = try self.state();
        if (token.adapter != self or value.fold_owner != token.generation) return false;
        value.busy = true;
        defer value.busy = false;
        return value.discardOwnedFolds();
    }
    pub fn releaseFolds(self: *Adapter, token: FoldToken) !bool {
        const value = try self.state();
        if (token.adapter != self or value.fold_owner != token.generation) return false;
        value.busy = true;
        defer value.busy = false;
        value.fold_owner = null;
        _ = value.discardOwnedFolds();
        return true;
    }
    pub fn folds(self: *const Adapter, destination: []Fold) ![]const Fold {
        const value = try self.state();
        try value.synchronize();
        const count = folding.count(value.folds);
        if (destination.len < count) return error.CapacityExceeded;
        if (value.folds) |set| {
            for (destination[0..count], set.entries) |*item, entry| item.* = entry.fold;
        }
        return destination[0..count];
    }
    pub fn foldHeaders(self: *const Adapter, destination: []FoldHeaderMark) ![]const FoldHeaderMark {
        const value = try self.state();
        const view = try ready(value, value.bounds, value.scale);
        if (destination.len < view.headers.len) return error.CapacityExceeded;
        @memcpy(destination[0..view.headers.len], view.headers);
        return destination[0..view.headers.len];
    }
    pub fn status(self: *const Adapter) !Status {
        const value = try self.state();
        const revision = try value.document.version();
        return .{ .revision = revision, .index_required = value.index_required or revision != value.observed, .folds_required = value.folds_required or value.pending_fold_restore or (revision != value.observed and value.folds != null), .fold_version = value.fold_version, .layout_required = value.layout_required or revision != value.observed, .last_layout_error = value.last_layout_error, .projection_active = if (value.view) |*view| view.projected and !value.layout_required and revision == value.observed else false, .line_backgrounds_required = value.line_backgrounds.len != 0 and value.background_text_version != try value.document.committedTextVersion(), .range_markers_required = value.range_markers.len != 0 and value.marker_text_version != try value.document.committedTextVersion() };
    }
    /// Optional composing adapters retain only lifetime, never text authority.
    pub fn retainClient(self: *Adapter) !void {
        const value = try self.state();
        value.clients = std.math.add(usize, value.clients, 1) catch return error.CapacityExceeded;
    }
    pub fn releaseClient(self: *Adapter) !void {
        const value = try self.state();
        if (value.clients == 0) return error.ClientNotAttached;
        value.clients -= 1;
    }
    /// Successful visible snapshot publication, including scroll/resize with
    /// unchanged document revision. Queries fail while a replacement is needed.
    pub fn viewVersion(self: *const Adapter) !u64 {
        const value = try self.state();
        _ = try ready(value, value.bounds, value.scale);
        return value.view_version;
    }
    /// Visible text geometry identity, independent of selection-only changes.
    /// This never permits bypassing the full revision gate for editing/input.
    pub fn projectionVersion(self: *const Adapter) !u64 {
        const value = try self.state();
        _ = try ready(value, value.bounds, value.scale);
        return value.projection_version;
    }
    pub fn ensureUnused(self: *const Adapter) !void {
        const value = try self.state();
        if (value.view) |*view| try view.ensureUnused();
    }
    pub fn sourceDocument(self: *const Adapter) !*d.Document {
        return (try self.state()).document;
    }
    pub fn stats(self: *const Adapter) !Stats {
        const value = try self.state();
        const addition = if (activeGeometry(value)) |geometry_value| geometry_value.total() else 0;
        return .{ .owned_bytes = value.budget.total(), .reserved_peak_bytes = value.budget.peak, .nodes = value.storage.nodes, .paragraphs = ix.sum(value.overlay orelse value.committed).rows, .layouts = value.entry_count, .shaped_batches = value.total_batches, .shaped_bytes = value.total_bytes, .visited_nodes = value.storage.visited, .reclaimed_nodes = value.storage.reclaimed, .scanned_rows = value.storage.scanned, .folds = folding.count(value.folds), .fold_version = value.fold_version, .visible_paragraphs = ix.sum(value.overlay orelse value.committed).visible_rows, .estimated_extent = @as(f64, @floatFromInt(ix.sum(value.overlay orelse value.committed).ticks + addition)) / ix.units };
    }
    pub fn prepare(self: *Adapter, bounds: Rect, parameters: Parameters) !PrepareResult {
        const value = try self.state();
        if (value.pre_input_running) return error.Busy;
        value.busy = true;
        defer value.busy = false;
        return prepareView(value, bounds, parameters) catch |err| {
            if (err != error.ResourceInUse) value.layout_required = true;
            value.last_layout_error = value.budget.normalize(err);
            return value.last_layout_error.?;
        };
    }
    /// Install a derived layout policy without changing text, selection or
    /// history. Active composition temporarily uses identity geometry. A text
    /// edit invalidates the plan stamp; cancel can restore the same old plan.
    pub fn setProjection(self: *Adapter, plan: ?*projection.Plan) !void {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        if (plan) |next| {
            if (next.document != value.document) return error.ForeignDocument;
            if (!try next.current()) return error.StaleRevision;
            try next.retainClient();
        }
        const old = value.projected_plan;
        value.projected_plan = plan;
        if (old != plan) value.projected_intra = null;
        value.layout_required = true;
        if (old != plan) {
            var previous: ?projection.Geometry = null;
            std.mem.swap(?projection.Geometry, &previous, &value.projected_geometry);
            if (previous) |*geometry_value| geometry_value.close(&value.storage);
        }
        if (old) |previous| previous.releaseClient();
    }
    /// Borrowed owner-thread policy identity, not ownership of the Plan.
    pub fn projectionPlan(self: *const Adapter) !?*projection.Plan {
        return (try self.state()).projected_plan;
    }
    pub fn draw(self: *Adapter, frame: *ui.Frame, bounds: Rect, colors: Colors) anyerror!void {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        return drawBody(frame, bounds, colors, value) catch |err| {
            frame.failure = frame.failure orelse err;
            return err;
        };
    }
    fn drawBody(frame: *ui.Frame, bounds: Rect, colors: Colors, value: *State) anyerror!void {
        const view = try ready(value, bounds, frame.size.scale);
        if (colors.caret_style) |style| {
            try style.validate();
            if (style.shape != .bar and !view.cells_enabled) return error.CaretCellsRequired;
            for (view.carets) |mark| try caret_visual.validateRect(caret_visual.terminal(mark.rect, if (style.shape == .bar) style.thickness else style.terminal_width));
            for (view.caret_cells) |rect| try caret_visual.validateRect(rect);
        }
        try frame.pushClip(bounds);
        defer frame.popClip() catch |err| {
            frame.failure = frame.failure orelse err;
        };
        for (view.line_backgrounds) |mark| {
            frame.rect(mark.rect, mark.color);
            if (frame.failure) |err| return @as(anyerror!void, err);
        }
        for (view.range_markers) |mark| if (mark.kind == .background) {
            frame.rect(mark.rect, mark.color);
            if (frame.failure) |err| return @as(anyerror!void, err);
        };
        for (view.marks) |mark| if (mark.kind == .selection) {
            frame.rect(mark.rect, colors.selection);
            if (frame.failure) |err| return @as(anyerror!void, err);
        };
        if (colors.caret_style) |style| try drawCarets(value, view, frame, colors.caret, style, true);
        if (value.mask_shaped) {
            try drawMasked(value, view, frame, bounds, colors.text);
        } else if (view.text_clips.len != 0) {
            try drawClippedText(value, view, frame, bounds, colors.text);
        } else if (view.projected) {
            var runs: RunIterator = .{ .view = view };
            while (try runs.next()) |run| {
                if (run.clip.width == 0 or run.clip.height == 0) continue;
                try frame.pushClip(run.clip);
                defer frame.popClip() catch |err| {
                    frame.failure = frame.failure orelse err;
                };
                try frame.preparedText(.{ .x = bounds.x - @as(f32, @floatCast(value.scroll_x)), .y = @floatCast(@as(f64, bounds.y) + run.y) }, try run.block.prepared.value.view(), colors.text);
                if (frame.context.window) |window| if (window.isClosed()) return error.Closed;
            }
        } else for (view.blocks[0..view.count]) |block| {
            try frame.preparedText(.{ .x = bounds.x - @as(f32, @floatCast(value.scroll_x)), .y = bounds.y + @as(f32, @floatCast(block.y)) }, try block.prepared.value.view(), colors.text);
            if (frame.context.window) |window| if (window.isClosed()) return error.Closed;
        }
        for (view.range_markers) |mark| if (mark.kind == .underline) {
            frame.rect(mark.rect, mark.color);
            if (frame.failure) |err| return @as(anyerror!void, err);
        };
        for (view.marks) |mark| if (mark.kind == .composition) {
            frame.rect(mark.rect, colors.composition);
            if (frame.failure) |err| return @as(anyerror!void, err);
        };
        if (colors.caret_style) |style| {
            try drawCarets(value, view, frame, colors.caret, style, false);
        } else if (value.token != null) for (view.carets) |mark| frame.rect(mark.rect, colors.caret);
        if (frame.failure) |err| return @as(anyerror!void, err);
    }
    /// A bullet centered in the advance of every placeholder grapheme.
    fn drawMasked(value: *State, view: *const View, frame: *ui.Frame, bounds: Rect, color: ui.Color) !void {
        const size = value.font.get().size;
        for (view.blocks[0..view.count]) |block| {
            for (try block.entry.layout.advanceSpans()) |span| {
                if (span.rect.width <= 0 or span.rect.height <= 0) continue;
                const radius = @min(size * 0.18, span.rect.width * 0.4);
                const x = bounds.x - @as(f32, @floatCast(value.scroll_x)) + span.rect.x + span.rect.width / 2;
                const y = bounds.y + @as(f32, @floatCast(block.y)) + span.rect.y + span.rect.height / 2;
                frame.roundedRect(.{ .x = x - radius, .y = y - radius, .width = 2 * radius, .height = 2 * radius }, radius, color);
                if (frame.failure) |err| return err;
            }
        }
    }
    pub fn hitTest(self: *Adapter, bounds: Rect, point: Point) !t.Caret {
        const value = try self.state();
        const view = try ready(value, bounds, value.scale);
        return hit(value, view, point);
    }
    /// Replay selected whole projected paragraphs once, without selection/IME
    /// or caret marks. This read-only display adds no alternate input state.
    /// IDs are strictly increasing source paragraph indices, borrowed only for
    /// this call. Prepared resources and clipping are shared with normal draw.
    pub fn drawParagraphs(self: *Adapter, frame: *ui.Frame, bounds: Rect, paragraphs: []const usize, color: ui.Color) anyerror!void {
        const value = try self.state();
        value.busy = true;
        defer value.busy = false;
        return drawParagraphsBody(frame, bounds, paragraphs, color, value) catch |err| {
            frame.failure = frame.failure orelse err;
            return err;
        };
    }
    fn drawParagraphsBody(frame: *ui.Frame, bounds: Rect, paragraphs: []const usize, color: ui.Color, value: *State) anyerror!void {
        const view = try ready(value, bounds, frame.size.scale);
        if (!view.projected) return error.ProjectionRequired;
        if (paragraphs.len > max_batches * cache.max_rows) return error.VisibleCapacityExceeded;
        const count = ix.sum(value.overlay orelse value.committed).rows;
        for (paragraphs, 0..) |line, at| if (line >= count or (at != 0 and line <= paragraphs[at - 1])) return error.InvalidParagraphs;
        try frame.pushClip(bounds);
        defer frame.popClip() catch |err| {
            frame.failure = frame.failure orelse err;
        };
        var selected: usize = 0;
        var runs: RunIterator = .{ .view = view };
        while (try runs.next()) |run| {
            const line = run.paragraph.?;
            while (selected < paragraphs.len and paragraphs[selected] < line) : (selected += 1) {}
            if (selected == paragraphs.len) break;
            if (paragraphs[selected] != line or run.clip.width == 0 or run.clip.height == 0) continue;
            try frame.pushClip(run.clip);
            defer frame.popClip() catch |err| {
                frame.failure = frame.failure orelse err;
            };
            try frame.preparedText(.{ .x = bounds.x - @as(f32, @floatCast(value.scroll_x)), .y = @floatCast(@as(f64, bounds.y) + run.y) }, try run.block.prepared.value.view(), color);
            if (frame.context.window) |window| if (window.isClosed()) return error.Closed;
        }
        if (frame.failure) |err| return @as(anyerror!void, err);
    }
    pub fn caretRect(self: *Adapter, bounds: Rect, scale: f32) !Rect {
        const value = try self.state();
        return (try ready(value, bounds, scale)).caret orelse error.CaretNotVisible;
    }
    pub fn selectionRects(self: *Adapter, destination: []Rect) ![]const Rect {
        const value = try self.state();
        const view = try ready(value, value.bounds, value.scale);
        var count: usize = 0;
        for (view.marks) |mark| count += @intFromBool(mark.kind == .selection);
        if (count > destination.len) return error.RectangleCapacityExceeded;
        var at: usize = 0;
        for (view.marks) |mark| if (mark.kind == .selection) {
            destination[at] = mark.rect;
            at += 1;
        };
        return destination[0..count];
    }
    pub fn caretRects(self: *Adapter, destination: []CaretMark) ![]const CaretMark {
        const value = try self.state();
        const view = try ready(value, value.bounds, value.scale);
        if (destination.len < view.carets.len) return error.CapacityExceeded;
        @memcpy(destination[0..view.carets.len], view.carets);
        return destination[0..view.carets.len];
    }
    /// Project committed document bytes through ONLY the prepared visible
    /// batches. No selection mutation, allocation, shaping or native query.
    /// UTF-8 boundaries inside a grapheme expand to its exact advance cells;
    /// hidden/offscreen text contributes no rectangle. Composition coordinates
    /// are deliberately excluded until committed. Capacity failure leaves the
    /// destination untouched; capacity uses the unclipped rectangle upper bound.
    pub fn rangeRects(self: *Adapter, expected_revision: u64, range: d.Range, destination: []t.Rect) ![]const t.Rect {
        const value = try self.state();
        if (expected_revision != try value.document.version()) return error.StaleRevision;
        if (try value.document.composition() != null) return error.CompositionActive;
        const view = try ready(value, value.bounds, value.scale);
        try value.validateRange(range);
        return preparedRangeRects(view, value.scroll_x, range, destination);
    }
    /// Exact cached caret geometry for a committed byte position. Returns null
    /// outside visible batches/folds; it never loads a hidden paragraph. An
    /// interior grapheme boundary snaps downstream, just like hit geometry.
    pub fn positionRect(self: *Adapter, expected_revision: u64, position: usize, affinity: t.Affinity) !?t.Rect {
        const value = try self.state();
        if (expected_revision != try value.document.version()) return error.StaleRevision;
        if (try value.document.composition() != null) return error.CompositionActive;
        const view = try ready(value, value.bounds, value.scale);
        try value.validateRange(.{ .start = position, .end = position });
        return preparedPositionRect(value, view, try value.currentIndex(), value.scroll_x, position, affinity);
    }
    /// Copy the same cached advance cells used by Prepared text, without native
    /// calls, allocation or shaping. Each cached span is visited once per pass.
    /// Capacity failure leaves destination untouched. A paragraph filter uses
    /// the same strictly increasing projected source IDs as drawParagraphs.
    /// Composition has no committed-document coordinate interpretation here.
    pub fn preparedGeometry(self: *Adapter, expected_revision: u64, destination: []GeometryCell, options: GeometryOptions) !PreparedGeometry {
        const value = try self.state();
        const view = try geometryView(value, expected_revision, options);
        const needed = try copyPreparedGeometry(view, value.scroll_x, options, null);
        if (needed > destination.len) return error.RectangleCapacityExceeded;
        const written = try copyPreparedGeometry(view, value.scroll_x, options, destination);
        std.debug.assert(needed == written);
        return .{ .cells = destination[0..written], .bounds = view.bounds, .scale = view.scale, .projection_version = value.projection_version };
    }
    /// Copy real cached system caret stops and visual lines from the matching
    /// Prepared. Zero-width stops and actual terminal empty lines are retained.
    /// No allocation, native query or shaping; capacity failure writes neither
    /// destination. Carets use Document UTF-8 byte positions and native affinity.
    pub fn preparedCarets(self: *Adapter, expected_revision: u64, carets: []GeometryCaret, lines: []GeometryLine, options: GeometryOptions) !PreparedCarets {
        const value = try self.state();
        const view = try geometryView(value, expected_revision, options);
        const needed = try copyPreparedCarets(value, view, options, null, null);
        if (needed.carets > carets.len or needed.lines > lines.len) return error.CaretCapacityExceeded;
        const written = try copyPreparedCarets(value, view, options, carets, lines);
        std.debug.assert(std.meta.eql(needed, written));
        return .{ .carets = carets[0..written.carets], .lines = lines[0..written.lines], .bounds = view.bounds, .scale = view.scale, .projection_version = value.projection_version };
    }
    /// Copy complete cached input routes and native coordinates. All buffers
    /// belong to the caller; capacity/work errors write none of them. This does
    /// not allocate, shape, retain a Layout, or change the visible exports.
    pub fn preparedHit(self: *Adapter, expected_revision: u64, buffers: PreparedHitBuffers) !PreparedHit {
        const value = try self.state();
        const view = try geometryView(value, expected_revision, .{});
        value.busy = true;
        defer value.busy = false;
        const projection_version = value.projection_version;
        const needed = try copyPreparedHit(value, view, null, value.limits.caret_work);
        if (needed.blocks > buffers.blocks.len or needed.lines > buffers.lines.len or needed.stops > buffers.stops.len or needed.placements > buffers.placements.len) return error.HitCapacityExceeded;
        // The second traversal has no foreign calls or fallible storage. Reserve
        // its entire work before writing any caller buffer.
        if (needed.work > value.limits.caret_work - needed.work) return error.WorkLimit;
        if (try value.document.version() != expected_revision or value.projection_version != projection_version) return error.StaleGeometry;
        const written = copyPreparedHit(value, view, buffers, needed.work) catch unreachable;
        std.debug.assert(std.meta.eql(needed, written));
        return .{ .packet = .{ .bounds = .{ .x = view.bounds.x, .y = view.bounds.y, .width = view.bounds.width, .height = view.bounds.height }, .scroll_x = value.scroll_x, .mode = @backingInt(if (view.projected) prepared_hit.Mode.projected else .ordinary), .block_count = @intCast(needed.blocks), .line_count = @intCast(needed.lines), .stop_count = @intCast(needed.stops), .placement_count = @intCast(needed.placements), .blocks = buffers.blocks.ptr, .lines = buffers.lines.ptr, .stops = buffers.stops.ptr, .placements = if (needed.placements == 0) null else buffers.placements.ptr }, .revision = expected_revision, .text_version = view.text_version, .projection_version = projection_version, .geometry_generation = view.geometry_generation, .scale = view.scale };
    }
    pub fn revealCaret(self: *Adapter) !void {
        const value = try self.state();
        try value.synchronize();
        value.reveal = true;
        value.layout_required = true;
    }
    /// The source-paragraph anchor of the current prepared viewport. It is
    /// derived geometry, independent of Document selection and undo.
    pub fn viewportAnchor(self: *Adapter) !ProjectionAnchor {
        const value = try self.state();
        _ = try ready(value, value.bounds, value.scale);
        return .{ .line = value.anchor.line, .intra_ticks = if (activeGeometry(value) != null) value.projected_intra orelse intraTicks(value.anchor.intra) else intraTicks(value.anchor.intra) };
    }
    pub fn scrollBy(self: *Adapter, delta: Point) !bool {
        const value = try self.state();
        try value.synchronize();
        if (!std.math.isFinite(delta.x) or !std.math.isFinite(delta.y) or @abs(delta.x) > 1000000 or @abs(delta.y) > 1000000) return error.InvalidScroll;
        return scrollState(value, delta);
    }
    pub fn bind(self: *Adapter, window: z.Window) !void {
        const value = try self.state();
        if (!value.configured) return error.LayoutRequired;
        if (value.token != null) return error.AlreadyBound;
        value.busy = true;
        defer value.busy = false;
        value.token = try window.setTextClient(.{ .context = value, .owner = value.owner, .read = clientRead, .change = clientChange, .unbound = clientUnbound });
    }
    pub fn isBound(self: *const Adapter) !bool {
        return (try self.state()).token != null;
    }
    /// Borrow the current native text binding for a host input transaction.
    /// Programmatic mutations inside this scope use the same final Document
    /// commit gate as native input. No Document guard remains between calls.
    /// Nested scopes preserve the original token and Space authorization.
    pub fn beginNativeInput(self: *Adapter, window: z.Window) !NativeInputScope {
        const value = try self.state();
        if (window.app.phase == .stopping or window.app.phase == .stopped or window.isClosed()) return error.Closed;
        _ = value.token orelse return error.NotBound;
        try boundWindow(value, window);
        const scope = window.beginCallback() orelse return error.Closed;
        errdefer scope.end();
        value.clients = std.math.add(usize, value.clients, 1) catch return error.CapacityExceeded;
        errdefer value.clients -= 1;
        const previous = value.native_input;
        value.native_input = previous orelse try value.captureNativeInput(window);
        errdefer value.native_input = previous;
        try value.checkNativeInput();
        return .{ .state = value, .previous = previous, .window_scope = scope };
    }
    /// Explicit local-DIP geometry for the retained native client. Context
    /// covers this borrow through unbind; Document remains the text authority.
    /// A passed stale token is rejected. The binding follows later successful
    /// frames, but never a released/recreated workspace or another attachment.
    pub fn setCommittedSpace(self: *Adapter, token: ui.SpaceToken) !void {
        const value = try self.state();
        const bound = value.token orelse return error.NotBound;
        const scope = bound.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        const binding = try token.binding();
        try binding.checkWindow(bound.window);
        if (value.token == null or !std.meta.eql(value.token.?, bound)) return error.StaleTextClient;
        if (!std.meta.eql(value.native_space, @as(?ui.SpaceBinding, binding))) {
            if (value.pointer_owner) |owner| {
                pointerRevoke(value, owner);
                owner.ignored_sequence = 0;
            }
        }
        value.native_space = binding;
    }
    /// Explicitly return to window-DIP geometry. Unbind also revokes the borrow.
    pub fn clearCommittedSpace(self: *Adapter) !void {
        const value = try self.state();
        if (value.native_space != null) {
            if (value.pointer_owner) |owner| {
                pointerRevoke(value, owner);
                owner.ignored_sequence = 0;
            }
        }
        value.native_space = null;
    }
    pub fn hasCommittedSpace(self: *const Adapter) !bool {
        return (try self.state()).native_space != null;
    }
    /// Reposition the native caret from already prepared layout. Suitable for
    /// a successful-front hook; this never prepares or shapes another layout.
    pub fn syncNativeCaret(self: *Adapter) !void {
        const value = try self.state();
        const bound = value.token orelse return error.NotBound;
        const scope = bound.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        _ = try ready(value, value.bounds, value.scale);
        try nativeCaret(value, bound.window);
    }
    pub fn unbind(self: *Adapter) !void {
        const value = try self.state();
        if (value.token) |token| _ = try token.window.clearTextClient(token);
        if (value.token != null) return error.UnbindPending;
    }
    /// Borrow one stable presentation observer. Only direct native TextClient
    /// changes notify it; normal handleEvent remains the host's update phase.
    pub fn observeNativeChanges(self: *Adapter, observer: NativeObserver) !NativeObserverToken {
        const value = try self.state();
        if (value.native_observer != null) return error.ObserverAttached;
        if (value.observer_generation == std.math.maxInt(u64)) return error.IdExhausted;
        value.observer_generation += 1;
        value.native_observer = observer;
        return .{ .adapter = self, .generation = value.observer_generation };
    }
    pub fn clearNativeObserver(self: *Adapter, token: NativeObserverToken) !bool {
        const value = try self.state();
        if (token.adapter != self or token.generation != value.observer_generation or value.native_observer == null) return false;
        value.native_observer = null;
        return true;
    }
    /// Shows the text as a password from the next prepare: a bullet for
    /// every scalar. The native text client reads placeholders of the same
    /// lengths instead of the text from now on.
    pub fn setMasked(self: *Adapter, on: bool) !void {
        const value = try self.state();
        if (value.busy) return error.Busy;
        // The view shaped before keeps drawing as it was shaped until the
        // next prepare, which shapes the text again.
        value.masked = on;
    }
    pub fn isMasked(self: *const Adapter) !bool {
        return (try self.state()).masked;
    }
    /// No allocation. Installation and clearing are forbidden from a running
    /// hook; the old context remains borrowed until this call succeeds.
    pub fn setPreInputHook(self: *Adapter, hook: ?PreInputHook) !void {
        const value = try self.state();
        if (value.pre_input_running) return error.Busy;
        value.pre_input = hook;
    }
    /// Explicit primary word/logical-row selection. The current native client
    /// and prepared Layout must already have word_ranges enabled. Supports
    /// ordinary Window-DIP or an explicitly committed Space, for one unfolded,
    /// unprojected Document.
    pub fn preparePointerSelection(self: *Adapter, window: z.Window) !void {
        const value = try self.state();
        comptime std.debug.assert(@sizeOf(PointerOwner) <= 4096);
        try pointerCapability(value, value.font.get());
        var scope = try self.beginNativeInput(window);
        defer scope.end();
        const before = scope.window_scope.record.pointerSequenceHighWater() orelse return error.UnsupportedCapability;
        if (before == std.math.maxInt(u64)) return error.IdExhausted;
        value.busy = true;
        defer value.busy = false;
        _ = try ready(value, value.bounds, value.scale);
        var candidate: ?*PointerOwner = null;
        defer if (candidate) |owned| value.allocator().destroy(owned);
        const owner = value.pointer_owner orelse blk: {
            const created = value.allocator().create(PointerOwner) catch |err| return value.budget.normalize(err);
            created.* = .{};
            candidate = created;
            break :blk created;
        };
        try value.checkNativeInput();
        try pointerCapability(value, value.font.get());
        _ = try ready(value, value.bounds, value.scale);
        _ = try pointerSpace(value, value.bounds);
        try value.checkNativeInput();
        const after = scope.window_scope.record.pointerSequenceHighWater() orelse return error.UnsupportedCapability;
        const revision = try value.document.version();
        // Unbind ends the old native issuer borrow. Retain semantic counters,
        // but do not compare its historical sequence floor against a new App
        // that may legitimately reuse the same address and Window slot value.
        var candidate_state = owner.state;
        if (!owner.bound) candidate_state = .{ .installation = owner.state.installation, .serial = owner.state.serial, .retired = owner.state.retired };
        try candidate_state.install(pointerWindow(window), @max(before, after));
        owner.state = candidate_state;
        owner.bound = true;
        owner.input = null;
        owner.last_up = .{};
        owner.ignored_sequence = 0;
        owner.selection_revision = revision;
        value.pointer_owner = owner;
        candidate = null;
        value.dragging = false;
    }
    /// Withdraw semantic selection and resume ordinary caret input only for
    /// fresh gestures. Bookkeeping remains in the Adapter budget until close.
    pub fn clearPointerSelection(self: *Adapter) !void {
        const value = try self.state();
        const owner = value.pointer_owner orelse return;
        const token = value.token;
        const scope = if (token) |bound| bound.window.beginCallback() else null;
        defer if (scope) |pinned| pinned.end();
        const floor = if (scope) |pinned| pinned.record.pointerSequenceHighWater() orelse owner.state.floor else owner.state.floor;
        owner.state.clear(floor);
        owner.input = null;
        owner.last_up = .{};
        owner.ignored_sequence = 0;
        value.dragging = false;
    }
    /// One host pointer route. Both failure fields describe an already-consumed
    /// route; no returned outcome authorizes replaying the same Adapter input.
    pub fn handlePointerEvent(self: *Adapter, window: z.Window, event: z.Event, bounds: Rect, parameters: Parameters) !PointerResult {
        const value = try self.state();
        const owner = value.pointer_owner orelse return error.PointerSelectionNotPrepared;
        switch (event) {
            .pointer_down, .pointer_up, .pointer_move => {},
            else => return error.InvalidPointerEvent,
        }
        if (value.pre_input_running) return error.Busy;
        _ = value.token orelse return error.NotBound;
        try boundWindow(value, window);
        const window_scope = window.beginCallback() orelse return error.Closed;
        value.clients = std.math.add(usize, value.clients, 1) catch {
            window_scope.end();
            return error.CapacityExceeded;
        };
        var scope: NativeInputScope = .{ .state = value, .previous = value.native_input, .window_scope = window_scope };
        defer scope.end();
        value.busy = true;
        defer value.busy = false;
        var result: PointerResult = .{ .handled = false };
        const semantic = owner.state.enabled;
        var mapped_event = event;
        var coordinate_generation: u64 = 0;
        // This is before the first native observer/allocator/SDK callback.
        pointerBegin(value, owner, window, event, bounds, parameters, &result) catch |err| {
            result.handled = true;
            result.input_error = value.budget.normalize(err);
        };
        if (result.input_error == null and result.handled) {
            if (pointerMap(value, owner, event, bounds, &result)) |mapped| {
                mapped_event = mapped.event;
                coordinate_generation = mapped.generation;
            } else |err| result.input_error = value.budget.normalize(err);
        }
        if (result.input_error == null and result.handled) {
            if (scope.previous) |previous| value.native_input = previous else {
                value.native_input = value.captureNativeInput(window) catch |err| blk: {
                    result.input_error = value.budget.normalize(err);
                    break :blk null;
                };
            }
            if (result.input_error == null and value.native_input.?.space_generation != coordinate_generation) result.input_error = error.StaleSpace;
            if (result.input_error == null) pointerProcess(value, owner, window, mapped_event, bounds, parameters, semantic, &result) catch |err| {
                if (result.selection_committed) result.presentation_error = value.budget.normalize(err) else result.input_error = value.budget.normalize(err);
            };
        }
        // Every retained Layout/probe and its foreign free has finished here.
        // The Adapter client pin still covers this owner and Budget.
        if (owner.input) |input| {
            var current = true;
            var eligible = false;
            value.checkNativeInput() catch |err| {
                current = false;
                pointerFailure(&result, err);
            };
            if (current) pointerRevision(value, owner) catch |err| {
                current = false;
                pointerFailure(&result, err);
            };
            if (current) {
                if (pointerCurrent(value, owner)) |snapshot| {
                    eligible = if (snapshot) |raw| raw.continuation_eligible else false;
                } else |err| {
                    current = false;
                    pointerFailure(&result, err);
                }
            }
            owner.state.finish(input.guard, current, eligible);
            if (input.guard.phase == .up and current and result.selection_committed) owner.last_up = input.press;
            owner.input = null;
        }
        return result;
    }
    pub fn handleEvent(self: *Adapter, window: z.Window, event: z.Event, bounds: Rect, parameters: Parameters) !bool {
        const value = try self.state();
        try boundWindow(value, window);
        if (value.pointer_owner) |owner| {
            switch (event) {
                .pointer_down, .pointer_move, .pointer_up => {
                    return pointerLegacy(self, window, event, bounds, parameters);
                },
                else => pointerLifecycle(value, owner, window, event),
            }
        }
        if (value.pre_input_running) switch (event) {
            .text_preedit_cancel, .text_preedit_revoked, .focus, .cancel_input => {},
            else => return error.Busy,
        };
        try boundWindow(value, window);
        if (event == .cancel_input or (event == .focus and !event.focus)) {
            value.dragging = false;
            return false;
        }
        if (value.native_space) |binding| try binding.checkWindow(window);
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const previous_input = value.native_input;
        value.native_input = previous_input orelse try value.captureNativeInput(window);
        defer value.native_input = previous_input;
        try value.checkNativeInput();
        const input: ?PreInput = switch (event) {
            .key_input => |key| .{ .key = key },
            .text_input => |text| .{ .text = text },
            .text_preedit => |preedit| .{ .preedit = preedit },
            else => null,
        };
        if (input) |typed| switch (try value.intercept(window, typed)) {
            .pass => {},
            .rejected => return true,
            .superseded => {
                value.presentIntercepted(window, bounds, parameters);
                return true;
            },
        };
        value.busy = true;
        defer value.busy = false;
        const routed = if (value.pointer_owner != null and event == .wheel) (try pointerWheel(value, event, bounds)) orelse return false else event;
        return eventInput(value, window, routed, bounds, parameters) catch |err| return value.budget.normalize(err);
    }
    pub fn handleKey(self: *Adapter, window: z.Window, input: z.KeyInput, bounds: Rect, parameters: Parameters) !bool {
        const value = try self.state();
        if (value.pre_input_running) return error.Busy;
        try boundWindow(value, window);
        if (value.pointer_owner) |owner| pointerRevoke(value, owner);
        if (value.native_space) |binding| try binding.checkWindow(window);
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const previous_input = value.native_input;
        value.native_input = previous_input orelse try value.captureNativeInput(window);
        defer value.native_input = previous_input;
        try value.checkNativeInput();
        switch (try value.intercept(window, .{ .key = input })) {
            .pass => {},
            .rejected => return true,
            .superseded => {
                value.presentIntercepted(window, bounds, parameters);
                return true;
            },
        }
        value.busy = true;
        defer value.busy = false;
        return keyInput(value, window, input, bounds, parameters) catch |err| return value.budget.normalize(err);
    }
};

fn drawCaretMark(frame: *ui.Frame, paint: caret_visual.Paint, clip: Rect, rgb: u32) void {
    const rect = ui.layout.intersect(.{ .x = paint.rect.x, .y = paint.rect.y, .width = paint.rect.width, .height = paint.rect.height }, clip);
    if (rect.width <= 0 or rect.height <= 0) return;
    var color = ui.Color.rgb(rgb);
    color.a = paint.alpha;
    frame.roundedRect(rect, 0, color);
}
fn drawCaretVisual(frame: *ui.Frame, visual: CaretVisual, cells: []const caret_visual.Rect, rgb: u32, style: caret_visual.Style, focused: bool, composing: bool, background: bool) void {
    const block = focused and visual.collapsed and !composing and style.shape == .block;
    if (background != block) return;
    if (!focused and (style.unfocused != .outline or !visual.collapsed or composing)) return;
    var effective = style;
    if (focused and (!visual.collapsed or composing)) effective.shape = .bar;
    const fallback = caret_visual.terminal(visual.native, if (effective.shape == .bar) style.thickness else style.terminal_width);
    const rects: []const caret_visual.Rect = if (effective.shape == .bar or cells.len == 0) &.{fallback} else cells;
    for (rects) |rect| {
        if (!focused) {
            const outline = caret_visual.outlined(rect, style.thickness);
            for (outline.items[0..outline.len]) |paint| drawCaretMark(frame, paint, visual.clip, rgb);
        } else drawCaretMark(frame, caret_visual.filled(rect, effective, block), visual.clip, rgb);
    }
}
fn drawCarets(state: *State, view: *const View, frame: *ui.Frame, rgb: u32, style: caret_visual.Style, background: bool) !void {
    if (!style.enabled) return;
    const focused = state.token != null and style.active;
    const composing = view.composition_revision != null;
    if (view.cells_enabled) {
        for (view.caret_visuals) |visual| drawCaretVisual(frame, visual, view.caret_cells[visual.first..][0..visual.count], rgb, style, focused, composing, background);
    } else {
        const selected = try state.allSelections();
        for (view.carets) |mark| {
            const item = selected.items[mark.selection];
            drawCaretVisual(frame, .{ .native = mark.rect, .clip = view.bounds, .first = 0, .count = 0, .collapsed = item.anchor == item.caret }, &.{}, rgb, style, focused, composing, background);
        }
    }
    if (frame.failure) |err| return err;
}
fn ready(self: *State, bounds: Rect, scale: f32) !*View {
    try validBounds(bounds);
    try self.synchronize();
    if (self.layout_required) return error.LayoutRequired;
    const view = if (self.view) |*view| view else return error.LayoutRequired;
    if (!std.meta.eql(bounds, view.bounds) or scale != view.scale or self.observed != view.revision) return error.LayoutRequired;
    return view;
}
fn resolveHit(self: *State, block: Block, input: t.Caret, ordinary: bool) !t.Caret {
    var position = input;
    position.byte_offset += block.byte;
    if (ordinary) {
        const root = try self.currentIndex();
        if (ix.get(&self.storage, root, ix.lineAt(&self.storage, root, position.byte_offset)).hidden) {
            position.byte_offset = block.byte + try block.entry.layout.graphemeByte(try block.entry.layout.graphemeCount() - 1);
            position.affinity = .upstream;
        }
    }
    return position;
}
const LiveHitReader = struct {
    state: *State,
    view: *const View,
    cached_block: ?usize = null,
    cached_lines: []const t.Line = &.{},
    pub fn mode(self: LiveHitReader) prepared_hit.Mode {
        return if (self.view.projected) .projected else .ordinary;
    }
    pub fn bounds(self: LiveHitReader) prepared_hit.Rect {
        const value = self.view.bounds;
        return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
    }
    pub fn scrollX(self: LiveHitReader) f64 {
        return self.state.scroll_x;
    }
    pub fn blockCount(self: LiveHitReader) usize {
        return self.view.count;
    }
    pub fn block(self: LiveHitReader, at: usize) HitBlock {
        const value = self.view.blocks[at];
        const last = value.entry.row_count - 1;
        return .{ .first = 0, .count = 0, .y = value.y, .end = value.y + (value.entry.tops[last] + value.entry.heights[last]) };
    }
    pub fn placementCount(self: LiveHitReader) usize {
        return self.view.placements.len;
    }
    pub fn placement(self: LiveHitReader, at: usize) HitPlacement {
        const item = self.view.placements[at];
        return .{ .block = @intCast(item.block), .y = item.y, .native_top = item.native_top, .height = item.height };
    }
    fn nativeLines(self: *LiveHitReader, at: usize) ![]const t.Line {
        if (self.cached_block != at) {
            self.cached_lines = try self.view.blocks[at].entry.layout.lines();
            self.cached_block = at;
        }
        return self.cached_lines;
    }
    pub fn lineCount(self: *LiveHitReader, at: usize) !usize {
        return (try self.nativeLines(at)).len;
    }
    pub fn nativeLine(self: *LiveHitReader, at: usize, line: usize) !prepared_hit.NativeLine {
        const item = (try self.nativeLines(at))[line];
        return .{ .y = item.y, .height = item.height };
    }
    pub fn lineStops(self: LiveHitReader, at: usize, line: usize) !cache.LineStops {
        const item = self.view.blocks[at];
        return cache.lineStops(item.entry, line, item.byte != 0);
    }
};
fn hit(self: *State, view: *const View, point: Point) !t.Caret {
    if (view.count == 0 or (view.projected and view.placements.len == 0)) return error.LayoutRequired;
    var reader: LiveHitReader = .{ .state = self, .view = view };
    const selected = try prepared_hit.select(&reader, .{ .x = point.x, .y = point.y });
    const stops = try reader.lineStops(selected.block, selected.line);
    return resolveHit(self, view.blocks[selected.block], stops.raw(selected.stop).caret, !view.projected);
}
const HitCounts = struct { blocks: usize = 0, lines: usize = 0, stops: usize = 0, placements: usize = 0, work: u64 = 0 };
fn copyPreparedHit(value: *State, view: *const View, destination: ?PreparedHitBuffers, work_limit: u64) !HitCounts {
    if (view.count == 0 or (view.projected and view.placements.len == 0)) return error.LayoutRequired;
    const reader: LiveHitReader = .{ .state = value, .view = view };
    var work: prepared_hit.Work = .{ .remaining = work_limit };
    var counts: HitCounts = .{};
    for (view.blocks[0..view.count], 0..) |block, bi| {
        try work.take(1);
        const native_lines = try block.entry.layout.lines();
        if (native_lines.len == 0) return error.InvalidParagraphMetrics;
        var exported_block = reader.block(bi);
        exported_block.first = @intCast(counts.lines);
        exported_block.count = @intCast(native_lines.len);
        if (destination) |buffers| buffers.blocks[bi] = exported_block;
        // The cache is already in native line/X order. A single raw cursor
        // visits every stop once; normal point input keeps its binary lookup.
        var cursor: usize = 0;
        for (native_lines, 0..) |line, li| {
            try work.take(1);
            const raw_first = cursor;
            while (cursor < block.entry.stops.len and block.entry.stops[cursor].line == li) : (cursor += 1) try work.take(1);
            const omitted: ?usize = if (block.byte != 0 and block.entry.first_upstream >= raw_first and block.entry.first_upstream < cursor) block.entry.first_upstream - raw_first else null;
            const stops: cache.LineStops = .{ .items = block.entry.stops[raw_first..cursor], .omitted = omitted };
            const first = counts.stops;
            for (0..stops.len()) |si| {
                try work.take(1);
                const raw = stops.raw(si);
                const result = try resolveHit(value, block, raw.caret, !view.projected);
                if (destination) |buffers| buffers.stops[counts.stops] = .{ .x = raw.rect.x, .position = result.byte_offset, .affinity = @backingInt(result.affinity) };
                counts.stops += 1;
            }
            if (destination) |buffers| buffers.lines[counts.lines] = .{ .y = line.y, .height = line.height, .first = @intCast(first), .count = @intCast(counts.stops - first) };
            counts.lines += 1;
        }
        if (cursor != block.entry.stops.len) return error.InvalidParagraphMetrics;
        counts.blocks += 1;
    }
    for (0..view.placements.len) |at| {
        try work.take(1);
        if (destination) |buffers| buffers.placements[at] = reader.placement(at);
        counts.placements += 1;
    }
    counts.work = work_limit - work.remaining;
    return counts;
}
fn savedParameters(self: *State) Parameters {
    return .{ .font = self.font.get(), .scale = self.scale, .version = self.parameters_version, .estimated_height = self.estimate, .caret_cells = self.caret_cells };
}
fn updateAfterInput(self: *State, window: z.Window, bounds: Rect, parameters: Parameters) !void {
    try self.checkNativeInput();
    if (self.native_space) |binding| try binding.checkWindow(window);
    _ = prepareView(self, bounds, parameters) catch |err| {
        self.layout_required = true;
        self.last_layout_error = self.budget.normalize(err);
        return error.LayoutRequired;
    };
    try nativeCaret(self, window);
    window.invalidate();
}
fn nativeCaret(self: *State, window: z.Window) !void {
    const authority = self.native_input orelse try self.captureNativeInput(window);
    try self.checkInput(authority);
    if (window.app.phase == .stopping or window.app.phase == .stopped or window.isClosed()) return error.Closed;
    if (self.native_space) |binding| try binding.checkWindow(window);
    if (self.view.?.caret) |caret| {
        const rect: Rect = .{ .x = caret.x, .y = caret.y, .width = caret.width, .height = caret.height };
        if (self.native_space) |binding| try binding.setTextCaret(rect) else try window.setTextCaret(rect);
    }
    try self.checkInput(authority);
}
fn clientRead(ptr: *anyopaque, window: z.Window, destination: []u8) !z.text.Snapshot {
    const self: *State = @ptrCast(@alignCast(ptr));
    if (self.busy) return error.Busy;
    const authority = self.native_input orelse try self.captureNativeInput(window);
    try self.checkInput(authority);
    if (window.app.phase == .stopping or window.app.phase == .stopped or window.isClosed()) return error.Closed;
    if (self.native_space) |binding| try binding.checkWindow(window);
    const result = try self.document.nativeContext(destination);
    // A password reaches input services as placeholders of the same length.
    if (self.masked) password_mask.apply(destination[0..result.bytes]);
    try self.checkInput(authority);
    return result;
}
fn clientChange(ptr: *anyopaque, window: z.Window, change: z.text.Change) !z.text.ChangeResult {
    const self: *State = @ptrCast(@alignCast(ptr));
    if (self.busy or self.pre_input_running) return error.Busy;
    const entry = self.native_input orelse try self.captureNativeInput(window);
    try self.checkInput(entry);
    if (window.app.phase == .stopping or window.app.phase == .stopped or window.isClosed()) return error.Closed;
    if (self.native_space) |binding| try binding.checkWindow(window);
    if (try self.document.selectionCount() != 1) return error.MultipleSelections;
    const before = try self.document.version();
    const hook_previous_input = self.native_input;
    self.native_input = hook_previous_input orelse entry;
    const intercepted = self.intercept(window, .{ .native_change = change }) catch |err| {
        self.native_input = hook_previous_input;
        return err;
    };
    if (intercepted != .pass) {
        if (intercepted == .superseded) self.presentIntercepted(window, self.bounds, savedParameters(self));
        self.native_input = hook_previous_input;
        const hook_revision = try self.document.version();
        const hook_observer = if (hook_revision != before) self.native_observer else null;
        const hook_notice: NativeChange = .{ .revision = hook_revision, .layout_error = self.last_layout_error };
        // No State access follows the observer: it may close an unbound owner.
        if (hook_observer) |callback| callback.call(callback.context, window, @ptrCast(self), hook_notice) catch |err| window.report(.{ .domain = .core, .operation = .text_input, .err = err });
        return if (intercepted == .rejected) .rejected else .superseded;
    }
    self.native_input = hook_previous_input;
    var observer: ?NativeObserver = null;
    var notice: NativeChange = undefined;
    var superseded = false;
    var committed = false;
    const failure: ?anyerror = blk: {
        self.busy = true;
        defer self.busy = false;
        const previous_input = self.native_input;
        self.native_input = previous_input orelse entry;
        defer self.native_input = previous_input;
        const outcome: ?anyerror = changed: {
            switch (change) {
                .select => |selected| _ = self.select(.{ .anchor = self.document.byteOffsetFromUtf16(selected.anchor) catch |err| break :changed err, .caret = self.document.byteOffsetFromUtf16(selected.caret) catch |err| break :changed err }, .downstream) catch |err| break :changed err,
                .replace => |replacement| _ = self.replace(.{ .start = self.document.byteOffsetFromUtf16(replacement.range.start) catch |err| break :changed err, .end = self.document.byteOffsetFromUtf16(replacement.range.end) catch |err| break :changed err }, replacement.text, false) catch |err| break :changed err,
            }
            updateAfterInput(self, window, self.bounds, savedParameters(self)) catch |err| break :changed err;
            break :changed null;
        };
        const revision = self.document.version() catch unreachable;
        committed = revision != before;
        if (revision != before and self.native_input.?.authority != null) self.checkNativeInput() catch {
            superseded = true;
        };
        if (revision != before) observer = self.native_observer;
        notice = .{ .revision = revision, .layout_error = outcome };
        break :blk outcome;
    };
    // Capture everything before user code. An observer can revoke/reinstall
    // itself or close a now-unbound Adapter; no State access may follow it.
    const notified = if (observer) |callback| callback.call(callback.context, window, @ptrCast(self), notice) else @as(anyerror!void, {});
    const notification_error: ?anyerror = if (notified) |_| null else |err| err;
    if (committed) {
        const lost_authority = superseded or (if (failure) |err| authorityError(err) else false) or (if (notification_error) |err| authorityError(err) else false);
        if (failure) |err| if (!authorityError(err)) window.report(.{ .domain = .core, .operation = .text_input, .err = err });
        if (notification_error) |err| if (!authorityError(err)) window.report(.{ .domain = .core, .operation = .text_input, .err = err });
        // Presentation cannot turn a completed Document change into an input
        // error that a native caller might replay. The observer returns only
        // its captured result; this branch never re-reads its possibly closed
        // Adapter or owner after that callback.
        return if (lost_authority) .superseded else .applied;
    }
    if (failure) |err| return err;
    if (notification_error) |err| return err;
    return .applied;
}
fn authorityError(err: anyerror) bool {
    return switch (err) {
        error.StalePresentation, error.GeometryRequired, error.StaleSpace, error.StaleTextClient, error.StaleTextInput, error.IdExhausted, error.Closed => true,
        else => false,
    };
}
fn clientUnbound(ptr: *anyopaque, window: z.Window, _: z.text.UnbindReason) void {
    const self: *State = @ptrCast(@alignCast(ptr));
    self.native_space = null;
    if (self.pointer_owner) |owner| {
        const record = window.app.windows.get(window.key);
        const floor = if (record) |current| current.pointerSequenceHighWater() orelse owner.state.floor else owner.state.floor;
        owner.state.clear(floor);
        owner.bound = false;
        owner.input = null;
        owner.last_up = .{};
        owner.ignored_sequence = 0;
    }
    const was_busy = self.busy;
    self.busy = true;
    defer self.busy = was_busy;
    self.token = null;
    self.dragging = false;
    const failure: ?anyerror = blk: {
        const before = self.document.version() catch |err| break :blk err;
        const known = !self.index_required and before == self.observed;
        const base_anchor = if (known) self.committedAnchor() catch |err| break :blk err else self.anchor;
        const changed = self.document.cancelComposition() catch |err| break :blk err;
        if (!known) {
            self.index_required = true;
            self.folds_required = self.folds != null or self.pending_fold_restore;
            folding.release(self.pending_folds);
            self.pending_folds = null;
            self.pending_fold_restore = false;
            self.layout_required = true;
            self.clearHistory();
        }
        if (changed) {
            ix.release(&self.storage, self.overlay);
            folding.release(self.overlay_folds);
            self.overlay_folds = null;
            self.overlay = null;
            self.observed = self.document.version() catch unreachable;
            self.layout_required = true;
            self.reveal = false;
            if (known) {
                self.anchor = base_anchor;
            }
        }
        break :blk null;
    };
    // Retain the adapter's own Document pin until Adapter.close. Unbinding does
    // not transfer ownership of this object or the caller's Engine/allocator.
    if (failure) |err| window.report(.{ .domain = .core, .operation = .text_input, .err = err });
}

fn scrollState(self: *State, delta: Point) !bool {
    try self.synchronize();
    if (!std.math.isFinite(delta.x) or !std.math.isFinite(delta.y) or @abs(delta.x) > 1000000 or @abs(delta.y) > 1000000) return error.InvalidScroll;
    const root = try self.currentIndex();
    const before = self.anchor;
    const before_projected = self.projected_intra;
    const old_x = self.scroll_x;
    if (activeGeometry(self)) |geometry_value| {
        const prefix = projectedPrefix(self, root, geometry_value, self.anchor.line);
        const offset = prefix + (self.projected_intra orelse intraTicks(self.anchor.intra));
        const target = shiftTicks(offset, delta.y, root.sum.ticks + geometry_value.total(), if (self.configured) self.bounds.height else 1);
        const line = geometry_value.atTick(&self.storage, root, target);
        self.projected_intra = target - projectedPrefix(self, root, geometry_value, line);
        self.anchor = .{ .line = line, .id = ix.get(&self.storage, root, line).id, .intra = @as(f64, @floatFromInt(self.projected_intra.?)) / ix.units };
    } else self.anchor = anchorShift(self, root, self.anchor, delta.y, if (self.configured) self.bounds.height else 1);
    self.scroll_x = std.math.clamp(self.scroll_x + delta.x, 0, max_scroll_x);
    const changed = !std.meta.eql(before, self.anchor) or before_projected != self.projected_intra or old_x != self.scroll_x;
    if (changed) {
        if (self.pointer_owner) |owner| pointerRevoke(self, owner);
        self.layout_required = true;
        self.reveal = false;
    }
    return changed;
}
fn boundWindow(self: *const State, window: z.Window) !void {
    if (self.token) |token| if (token.window.app != window.app or !std.meta.eql(token.window.key, window.key)) return error.WrongWindow;
}
noinline fn pointerLegacy(adapter: *Adapter, window: z.Window, event: z.Event, bounds: Rect, parameters: Parameters) !bool {
    const result = try adapter.handlePointerEvent(window, event, bounds, parameters);
    if (result.input_error) |err| window.report(.{ .domain = .core, .operation = .text_input, .err = err });
    if (result.presentation_error) |err| window.report(.{ .domain = .core, .operation = .text_input, .err = err });
    return result.handled;
}
noinline fn pointerBeforeMutation(self: *State, owner: *PointerOwner) !void {
    try pointerRevision(self, owner);
    _ = try pointerCurrent(self, owner);
}
noinline fn pointerValidateCommit(self: *State, owner: *PointerOwner) !void {
    _ = try pointerCurrent(self, owner);
}
fn pointerFailure(result: *PointerResult, err: anyerror) void {
    if (result.selection_committed) result.presentation_error = result.presentation_error orelse err else result.input_error = result.input_error orelse err;
}
fn pointerWindow(window: z.Window) pointer_selection.Window {
    return .{ .app = @intFromPtr(window.app), .index = window.key.index, .generation = window.key.generation };
}
fn pointerCapability(self: *State, font: t.Options) !void {
    if (!self.configured) return error.LayoutRequired;
    if (!font.word_ranges or !self.font.options.word_ranges) return error.WordRangesNotEnabled;
    if (self.projected_plan != null or self.projected_geometry != null or self.fold_owner != null or folding.count(self.folds) != 0 or folding.count(self.overlay_folds) != 0 or self.pending_fold_restore) return error.UnsupportedPointerGeometry;
}
fn pointerRoute(self: *State) !pointer_selection.Route {
    var route: pointer_selection.Route = .{ .text_version = try self.document.committedTextVersion(), .layout_generation = self.generation, .scale = self.scale, .bounds = .{ self.bounds.x, self.bounds.y, self.bounds.width, self.bounds.height }, .scroll_x = self.scroll_x, .anchor_id = self.anchor.id, .anchor_intra = self.anchor.intra };
    if (self.native_space) |binding| {
        const token = try pointerSpace(self, self.bounds) orelse unreachable;
        route.space_owner = @intFromPtr(binding.context);
        route.space_epoch = binding.epoch;
        route.space_id = binding.id;
        route.space_geometry = try token.geometryVersion();
    }
    return route;
}
fn pointerSpace(self: *State, bounds: Rect) !?ui.SpaceToken {
    const binding = self.native_space orelse return null;
    const token = try binding.resolve();
    if (!std.meta.eql(try token.localBounds(), ui.affine.Rect.from(bounds))) return error.GeometryRequired;
    return token;
}
const PointerMapped = struct { event: z.Event, generation: u64 = 0 };
fn pointerMap(self: *State, owner: *PointerOwner, event: z.Event, bounds: Rect, result: *PointerResult) !PointerMapped {
    const token = try pointerSpace(self, bounds);
    if (event == .pointer_down) {
        const inside = if (token) |space| try space.contains(event.pointer_down.position) else bounds.contains(event.pointer_down.position);
        if (!inside) {
            pointerRevoke(self, owner);
            // This route did not consume the down. Its exact paired release
            // is also ignored; the receipt lends no selection authority.
            owner.ignored_sequence = event.pointer_down.press.sequence;
            result.handled = false;
            return .{ .event = event };
        }
    }
    return if (token) |space| .{ .event = try space.mapEvent(event, .{}), .generation = space.generation } else .{ .event = event };
}
noinline fn pointerWheel(self: *State, event: z.Event, bounds: Rect) !?z.Event {
    const token = try pointerSpace(self, bounds) orelse return event;
    if (!try token.contains(event.wheel.position)) return null;
    const mapped = try token.mapEvent(event, .{});
    // Physical wheel axes remain the existing policy. Only the hit position
    // is mapped, using the very same exact transaction as native text input.
    try self.checkNativeInput();
    return mapped;
}
fn pointerCurrent(self: *State, owner: *PointerOwner) !?z.PointerPressSnapshot {
    const input = owner.input orelse return error.StalePointerInput;
    if (self.pointer_owner != owner or !owner.state.valid(input.guard)) return error.StalePointerInput;
    const record = input.window.app.windows.get(input.window.key) orelse return error.Closed;
    if (!record.pointerCurrent(input.guard.operation)) return error.StalePointerInput;
    if (input.guard.phase == .move) return null;
    const snapshot = try input.window.pointerPressSnapshot(input.press, if (input.guard.phase == .down) .down else .up);
    if (snapshot.button != .primary) return error.StalePointerInput;
    return snapshot;
}
fn pointerRevision(self: *State, owner: *PointerOwner) !void {
    const input = owner.input orelse return;
    if (try self.document.version() != input.revision) return error.StaleRevision;
}
fn pointerBegin(self: *State, owner: *PointerOwner, window: z.Window, event: z.Event, bounds: Rect, parameters: Parameters, result: *PointerResult) !void {
    try validBounds(bounds);
    const point = switch (event) {
        .pointer_down => |input| input.position,
        .pointer_up => |input| input.position,
        .pointer_move => |input| input,
        else => unreachable,
    };
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidPoint;
    if (!owner.state.enabled) {
        const sequence = switch (event) {
            .pointer_down => |input| input.press.sequence,
            .pointer_up => |input| input.press.sequence,
            else => 0,
        };
        if (!owner.state.ordinaryAllowed(pointerWindow(window), sequence)) {
            result.handled = true;
            return error.StalePointerInput;
        }
        result.handled = if (event == .pointer_down) (self.native_space != null or bounds.contains(point)) else self.dragging;
        return;
    }
    const record = window.app.windows.get(window.key) orelse return error.Closed;
    const operation = record.pointerOperation();
    if (!record.pointerCurrent(operation)) return error.StalePointerInput;
    if (event == .pointer_up and event.pointer_up.button == .primary and owner.ignored_sequence != 0 and owner.ignored_sequence == event.pointer_up.press.sequence) {
        // The saved disposition cannot authorize an event: require the exact
        // current native release before bypassing all Document/Space work.
        const raw = try window.pointerPressSnapshot(event.pointer_up.press, .up);
        if (raw.button != .primary) return error.StalePointerInput;
        owner.ignored_sequence = 0;
        return;
    }
    const revision = try self.document.version();
    if (revision != owner.selection_revision) {
        owner.state.revoke();
        owner.last_up = .{};
        self.dragging = false;
        if (event != .pointer_down) return error.StaleRevision;
    }
    const guard = switch (event) {
        .pointer_down => |input| blk: {
            owner.last_up = .{};
            if (input.button != .primary) {
                pointerRevoke(self, owner);
                return;
            }
            result.handled = true;
            const raw = try window.pointerPressSnapshot(input.press, .down);
            if (raw.button != input.button) return error.StalePointerInput;
            owner.ignored_sequence = 0;
            break :blk try owner.state.beginDown(.{ .window = pointerWindow(window), .operation = operation, .sequence = input.press.sequence, .previous_completed_sequence = raw.previous_completed_sequence, .timing = raw.timing });
        },
        .pointer_up => |input| blk: {
            if (input.button != .primary) return;
            result.handled = self.dragging or bounds.contains(point);
            const raw = try window.pointerPressSnapshot(input.press, .up);
            if (raw.button != input.button) return error.StalePointerInput;
            break :blk try owner.state.beginUp(pointerWindow(window), operation, input.press.sequence);
        },
        .pointer_move => blk: {
            if (!self.dragging) return;
            result.handled = true;
            break :blk try owner.state.beginMove(pointerWindow(window), operation);
        },
        else => unreachable,
    };
    owner.input = .{ .guard = guard, .window = window, .press = switch (event) {
        .pointer_down => |input| input.press,
        .pointer_up => |input| input.press,
        else => .{},
    }, .revision = revision };
    // An up is taken exactly once even if preparation or a final guard fails.
    if (event == .pointer_up) self.dragging = false;
    try pointerCapability(self, parameters.font);
    if (event == .pointer_down) {
        const modifiers = event.pointer_down.modifiers;
        if (modifiers.control or modifiers.alt or modifiers.super) return error.UnsupportedPointerModifiers;
    }
}
fn pointerUnit(self: *State, target: t.Caret, count: u8) !pointer_selection.Range {
    if (count == 1) return .{ .start = target.byte_offset, .end = target.byte_offset };
    const root = try self.currentIndex();
    const line = paragraphFor(self, root, target.byte_offset, target.affinity);
    const row = ix.get(&self.storage, root, line);
    const start = ix.prefix(&self.storage, root, line).bytes;
    if (count == 3) return .{ .start = start, .end = start + row.bytes };
    const current = try probe(self, line);
    defer current.close();
    const text = try current.entry.layout.text();
    var end = start + row.bytes;
    // Index rows include LF and its preceding CR. Neither belongs to a word
    // unit, even when a multi-row native nonword span crosses both newlines.
    if (row.terminated) {
        end -= 1;
        if (end > start and text[end - 1 - current.byte] == '\r') end -= 1;
    }
    if (start == end) return .{ .start = start, .end = start };
    var caret = target;
    caret.byte_offset = std.math.clamp(caret.byte_offset, start, end);
    if (caret.byte_offset == start) caret.affinity = .downstream else if (caret.byte_offset == end) caret.affinity = .upstream;
    caret.byte_offset -= current.byte;
    const word = try current.entry.layout.wordRangeAt(caret);
    return .{ .start = @max(start, current.byte + word.start), .end = @min(end, current.byte + word.end) };
}
fn pointerProcess(self: *State, owner: *PointerOwner, window: z.Window, event: z.Event, bounds: Rect, parameters: Parameters, semantic: bool, result: *PointerResult) !void {
    try self.checkNativeInput();
    if (semantic and owner.input == null) return error.StalePointerInput;
    if (event == .pointer_down) _ = try self.cancel();
    _ = try prepareView(self, bounds, parameters);
    if (semantic) {
        if (owner.input == null) return error.StalePointerInput;
        try pointerCapability(self, parameters.font);
    }
    if (owner.input != null) {
        try pointerRevision(self, owner);
        _ = try pointerCurrent(self, owner);
    }
    const point = switch (event) {
        .pointer_down => |input| input.position,
        .pointer_up => |input| input.position,
        .pointer_move => |input| input,
        else => unreachable,
    };
    const target = try hit(self, &self.view.?, .{ .x = point.x, .y = if (event == .pointer_down) point.y else std.math.clamp(point.y, bounds.y, bounds.y + bounds.height) });
    var selected: d.Selection = undefined;
    var count: u8 = 1;
    var unit: pointer_selection.Range = .{ .start = target.byte_offset, .end = target.byte_offset };
    if (owner.input) |input| {
        if (event == .pointer_down) {
            const modifiers = event.pointer_down.modifiers;
            count = try owner.state.propose(input.guard, try pointerRoute(self), !modifiers.shift);
            unit = try pointerUnit(self, target, count);
            selected = if (modifiers.shift) .{ .anchor = (try self.document.selection()).anchor, .caret = target.byte_offset } else .{ .anchor = unit.start, .caret = unit.end };
        } else {
            const held = try owner.state.heldFor(input.guard);
            if (held.route.text_version != try self.document.committedTextVersion() or held.route.layout_generation != self.generation) return error.StalePointerInput;
            const route = try pointerRoute(self);
            if (held.route.space_owner != route.space_owner or held.route.space_epoch != route.space_epoch or held.route.space_id != route.space_id or held.route.space_geometry != route.space_geometry) return error.StalePointerInput;
            count = held.proposal.count;
            unit = try pointerUnit(self, target, count);
            const drag = pointer_selection.drag(held, unit);
            selected = .{ .anchor = drag.anchor, .caret = drag.caret };
        }
    } else selected = if (event == .pointer_down) .{ .anchor = target.byte_offset, .caret = target.byte_offset } else .{ .anchor = (try self.document.selection()).anchor, .caret = target.byte_offset };
    _ = try self.select(selected, if (count == 1) target.affinity else if (selected.caret < selected.anchor) .downstream else .upstream);
    result.selection_committed = true;
    owner.selection_revision = try self.document.version();
    self.preferred_x = null;
    if (owner.input) |input| {
        if (event == .pointer_down) try owner.state.acceptDown(input.guard, unit, selected.anchor) else try owner.state.acceptDrag(input.guard);
    } else if (semantic) return error.StalePointerInput;
    if (event == .pointer_down) self.dragging = true;
    updateAfterInput(self, window, bounds, parameters) catch |err| {
        result.presentation_error = self.budget.normalize(err);
    };
}
noinline fn pointerLifecycle(self: *State, owner: *PointerOwner, window: z.Window, event: z.Event) void {
    switch (event) {
        .focus => |focused| if (focused) return,
        .cancel_input => {
            if (owner.last_up.sequence != 0) {
                const raw = window.pointerPressSnapshot(owner.last_up, .up) catch null;
                if (raw != null and raw.?.button == .primary) return;
            }
        },
        .window_position, .resize, .window_state, .wheel, .key_input, .edit_key, .text_input, .text_preedit, .text_preedit_cancel, .text_preedit_revoked => {},
        else => return,
    }
    pointerRevoke(self, owner);
}
fn pointerRevoke(self: *State, owner: *PointerOwner) void {
    owner.state.revoke();
    owner.input = null;
    owner.last_up = .{};
    self.dragging = false;
}

fn eventInput(self: *State, window: z.Window, event: z.Event, bounds: Rect, parameters: Parameters) !bool {
    switch (event) {
        .paint, .window_state, .window_position, .text_preedit_revoked => return false,
        .resize => {
            try updateAfterInput(self, window, bounds, parameters);
            return false;
        },
        .key_input => |input| return keyInput(self, window, input, bounds, parameters),
        .edit_key => |input| return keyInput(self, window, .{ .key = switch (input.key) {
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
        }, .modifiers = .{ .shift = input.shift, .control = input.control } }, bounds, parameters),
        .key => return false,
        .focus => |focused| {
            if (!focused) self.dragging = false;
            return false;
        },
        .cancel_input => {
            self.dragging = false;
            return false;
        },
        .text_input => |input| {
            if (self.token == null) return false;
            _ = try self.replaceSelections(if (std.mem.eql(u8, input.text, "\r")) "\n" else input.text, try self.document.composition() != null);
        },
        .text_preedit => |marked| {
            if (self.token == null) return false;
            if (std.mem.indexOfScalar(u8, marked.text, 0) != null) return error.EmbeddedNul;
            try self.preedit(marked.text, .{ .anchor = marked.selection_start, .caret = marked.selection_end });
        },
        .text_preedit_cancel => {
            if (!try self.cancel()) return true;
        },
        .wheel => |wheel| {
            if (!bounds.contains(wheel.position)) return false;
            if (!try scrollState(self, .{ .x = wheel.delta.x, .y = wheel.delta.y })) return false;
        },
        .pointer_down => |pointer| {
            const point = pointer.position;
            if (!bounds.contains(point)) return false;
            _ = try self.cancel();
            _ = try prepareView(self, bounds, parameters);
            const target = try hit(self, &self.view.?, .{ .x = point.x, .y = point.y });
            _ = try self.select(.{ .anchor = target.byte_offset, .caret = target.byte_offset }, target.affinity);
            self.dragging = true;
            self.preferred_x = null;
        },
        .pointer_move, .pointer_up => {
            const point = if (event == .pointer_up) event.pointer_up.position else event.pointer_move;
            if (!self.dragging) return false;
            if (event == .pointer_up) self.dragging = false;
            _ = try prepareView(self, bounds, parameters);
            const target = try hit(self, &self.view.?, .{ .x = point.x, .y = std.math.clamp(point.y, bounds.y, bounds.y + bounds.height) });
            _ = try self.select(.{ .anchor = (try self.document.selection()).anchor, .caret = target.byte_offset }, target.affinity);
        },
    }
    try updateAfterInput(self, window, bounds, parameters);
    return true;
}
const Probe = struct {
    entry: *cache.Entry,
    first: usize,
    byte: usize,
    fn close(self: Probe) void {
        self.entry.release();
    }
};
fn probe(self: *State, line: usize) !Probe {
    var work: Working = .{ .state = self, .allow_hidden = true, .folds = folding.retain(if (self.overlay != null) self.overlay_folds else self.folds), .root = ix.retain(try self.currentIndex()).?, .anchor = self.anchor, .view = .{ .bounds = self.bounds, .scale = self.scale, .revision = self.observed }, .generation = self.generation, .font = self.font.get(), .parameters = savedParameters(self) };
    defer work.close();
    const loaded = try work.load(line, true);
    return .{ .entry = loaded.entry.retain(), .first = loaded.first, .byte = ix.prefix(&self.storage, work.root, loaded.first).bytes };
}
fn caretLine(self: *State, root: *ix.Node, byte: usize) usize {
    return paragraphFor(self, root, byte, self.affinity);
}
fn paragraphFor(self: *State, root: *ix.Node, byte: usize, affinity: t.Affinity) usize {
    const line = ix.lineAt(&self.storage, root, byte);
    return if (line > 0 and affinity == .upstream and ix.prefix(&self.storage, root, line).bytes == byte and !ix.get(&self.storage, root, line - 1).hidden) line - 1 else line;
}
fn graphemeIndex(layout: *const t.Layout, byte: usize) !usize {
    var low: usize = 0;
    var high = try layout.graphemeCount();
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (try layout.graphemeByte(middle) < byte) low = middle + 1 else high = middle;
    }
    return low;
}
fn visualStep(entry: *cache.Entry, current: t.Caret, rect: t.Rect, forwards: bool, has_previous: bool) !?t.Caret {
    const line = cache.lineAt(try entry.layout.lines(), rect.y + rect.height * 0.5);
    if (forwards) {
        for (entry.stops) |stop| if (stop.line == line and stop.rect.x > rect.x) return try cache.hitTest(entry, .{ .x = stop.rect.x, .y = stop.rect.y + stop.rect.height * 0.5 }, has_previous);
        for (entry.stops) |stop| if (stop.line > line) return try cache.hitTest(entry, .{ .x = stop.rect.x, .y = stop.rect.y + stop.rect.height * 0.5 }, has_previous);
    } else {
        var at = entry.stops.len;
        while (at > 0) {
            at -= 1;
            const stop = entry.stops[at];
            if (stop.line == line and stop.rect.x < rect.x) return try cache.hitTest(entry, .{ .x = stop.rect.x, .y = stop.rect.y + stop.rect.height * 0.5 }, has_previous);
        }
        at = entry.stops.len;
        while (at > 0) {
            at -= 1;
            if (entry.stops[at].line < line) return try cache.hitTest(entry, .{ .x = entry.stops[at].rect.x, .y = entry.stops[at].rect.y + entry.stops[at].rect.height * 0.5 }, has_previous);
        }
    }
    _ = current;
    return null;
}
fn neighbor(self: *State, current: Probe, backwards: bool, x: f32) !t.Caret {
    const root = try self.currentIndex();
    const next = if (backwards) ix.previousVisible(&self.storage, root, current.first) else ix.nextVisible(&self.storage, root, current.first + current.entry.row_count);
    const next_line = next orelse {
        if (backwards) return .{ .byte_offset = 0 };
        if (!ix.get(&self.storage, root, root.sum.rows - 1).hidden) return .{ .byte_offset = root.sum.bytes };
        const count = try current.entry.layout.graphemeCount();
        return .{ .byte_offset = current.byte + try current.entry.layout.graphemeByte(count - 1), .affinity = .upstream };
    };
    const other = try probe(self, next_line);
    defer other.close();
    const lines = try other.entry.layout.lines();
    var line: usize = 0;
    if (backwards) {
        const last = next_line - other.first;
        const bottom = other.entry.tops[last] + other.entry.heights[last];
        for (lines, 0..) |item, at| if (item.y < bottom) {
            line = at;
        };
    }
    var target = try cache.hitTest(other.entry, .{ .x = x, .y = lines[line].y + lines[line].height * 0.5 }, other.byte != 0);
    target.byte_offset += other.byte;
    return target;
}
fn deleteSelections(self: *State, backwards: bool) !void {
    const selected = try self.document.selections(self.selection_buffer);
    const edits = try self.allocator().alloc(d.Replacement, selected.items.len);
    defer self.allocator().free(edits);
    const root = try self.currentIndex();
    const shape_start = self.total_bytes;
    var count: usize = 0;
    for (selected.items, 0..) |item, selection_index| {
        var range = item.range();
        if (range.start != range.end) {
            const first = try probe(self, ix.lineAt(&self.storage, root, range.start));
            defer first.close();
            const last = try probe(self, ix.lineAt(&self.storage, root, range.end));
            defer last.close();
            range.start = first.byte + try cache.snap(first.entry.layout, range.start - first.byte, false);
            range.end = last.byte + try cache.snap(last.entry.layout, range.end - last.byte, true);
        } else {
            const affinity = self.affinityAt(selection_index, selected.primary);
            var line = ix.lineAt(&self.storage, root, item.caret);
            if (affinity == .upstream and line > 0 and ix.prefix(&self.storage, root, line).bytes == item.caret and !ix.get(&self.storage, root, line - 1).hidden) line -= 1;
            const current = try probe(self, line);
            defer current.close();
            const local = try cache.snap(current.entry.layout, item.caret - current.byte, true);
            const gi = try graphemeIndex(current.entry.layout, local);
            if (backwards) {
                if (gi > 0) range.start = current.byte + try current.entry.layout.graphemeByte(gi - 1) else if (current.first > 0) {
                    const previous = try probe(self, current.first - 1);
                    defer previous.close();
                    range.start = previous.byte + try previous.entry.layout.graphemeByte(try graphemeIndex(previous.entry.layout, item.caret - previous.byte) - 1);
                }
            } else if (gi < try current.entry.layout.graphemeCount()) range.end = current.byte + try current.entry.layout.graphemeByte(gi + 1);
        }
        if (self.total_bytes - shape_start > self.limits.shaped_bytes) return error.ShapeBudgetExceeded;
        if (range.start == range.end) continue;
        edits[count] = .{ .range = range, .text = "" };
        count += 1;
    }
    if (count == 0) return;
    std.mem.sort(d.Replacement, edits[0..count], {}, struct {
        fn less(_: void, a: d.Replacement, b: d.Replacement) bool {
            return a.range.start < b.range.start or (a.range.start == b.range.start and a.range.end < b.range.end);
        }
    }.less);
    var merged: usize = 0;
    for (edits[0..count]) |edit| {
        if (merged != 0 and edit.range.start <= edits[merged - 1].range.end) edits[merged - 1].range.end = @max(edits[merged - 1].range.end, edit.range.end) else {
            edits[merged] = edit;
            merged += 1;
        }
    }
    _ = try self.replaceMany(edits[0..merged], .mapped, "");
}
fn verticalTarget(self: *State, initial: Probe, x: f32, y: f64, shape_start: u64) !t.Caret {
    var current = initial;
    current.entry = current.entry.retain();
    defer current.close();
    var local_y = y;
    const root = try self.currentIndex();
    while (true) {
        const last = current.entry.row_count - 1;
        const bottom = current.entry.tops[last] + current.entry.heights[last];
        if (local_y >= 0 and local_y < bottom) {
            var target = try cache.hitTest(current.entry, .{ .x = x, .y = @floatCast(local_y) }, current.byte != 0);
            target.byte_offset += current.byte;
            return target;
        }
        const before = local_y < 0;
        const next = if (before) ix.previousVisible(&self.storage, root, current.first) else ix.nextVisible(&self.storage, root, current.first + current.entry.row_count);
        if (next == null) {
            const lines = try current.entry.layout.lines();
            const line = cache.lineAt(lines, @floatCast(if (before) @as(f64, 0) else bottom - current.entry.heights[last] * 0.5));
            var target = try cache.hitTest(current.entry, .{ .x = x, .y = lines[line].y + lines[line].height * 0.5 }, current.byte != 0);
            target.byte_offset += current.byte;
            return target;
        }
        const other = try probe(self, next.?);
        if (self.total_bytes - shape_start > self.limits.shaped_bytes) {
            other.close();
            return error.ShapeBudgetExceeded;
        }
        if (before) {
            const row = next.? - other.first;
            local_y += other.entry.tops[row] + other.entry.heights[row];
        } else local_y = local_y - bottom + other.entry.tops[next.? - other.first];
        current.close();
        current = other;
    }
}
fn projectedPageTarget(self: *State, current: Probe, source_line: usize, rect: t.Rect, x: f32, delta: f64, shape_start: u64) !t.Caret {
    const value = activeGeometry(self) orelse unreachable;
    const root = try self.currentIndex();
    const local = @as(f64, rect.y) + @as(f64, rect.height) * 0.5 - current.entry.tops[source_line - current.first];
    const absolute = projectedPrefix(self, root, value, source_line) + value.gap(source_line) + intraTicks(local);
    const total = root.sum.ticks + value.total();
    const target = @min(shiftTicks(absolute, delta, total, 0), total -| 1);
    const line = value.atTick(&self.storage, root, target);
    const loaded = try probe(self, line);
    defer loaded.close();
    if (self.total_bytes - shape_start > self.limits.shaped_bytes) return error.ShapeBudgetExceeded;
    const offset = line - loaded.first;
    const native_top = loaded.entry.tops[offset];
    const height = loaded.entry.heights[offset];
    const relative_y = difference(target, projectedPrefix(self, root, value, line) + value.gap(line));
    var native_y: f32 = @floatCast(native_top + relative_y);
    if (relative_y <= 0 or relative_y >= height) {
        const before = relative_y <= 0;
        var found = false;
        for (try loaded.entry.layout.lines()) |native_line| {
            const center = @as(f64, native_line.y) + @as(f64, native_line.height) * 0.5;
            if (center < native_top or center >= native_top + height) continue;
            native_y = @floatCast(center);
            found = true;
            if (before) break;
        }
        if (!found) return error.InvalidParagraphMetrics;
    }
    var result = try cache.hitTest(loaded.entry, .{ .x = x, .y = native_y }, loaded.byte != 0);
    result.byte_offset += loaded.byte;
    return result;
}
fn moveOne(self: *State, selected: d.Selection, affinity: t.Affinity, preferred: ?f32, input: z.KeyInput, bounds: Rect, shape_start: u64) !Movement {
    const root = try self.currentIndex();
    var line = ix.lineAt(&self.storage, root, selected.caret);
    if (affinity == .upstream and line > 0 and ix.prefix(&self.storage, root, line).bytes == selected.caret and !ix.get(&self.storage, root, line - 1).hidden) line -= 1;
    const current = try probe(self, line);
    defer current.close();
    const local = try cache.snap(current.entry.layout, selected.caret - current.byte, true);
    const caret: t.Caret = .{ .byte_offset = local, .affinity = affinity };
    const rect = try current.entry.layout.caret(caret);
    var target: t.Caret = .{ .byte_offset = selected.caret, .affinity = affinity };
    var preferred_x = preferred;
    switch (input.key) {
        .left, .right => {
            preferred_x = null;
            if (!input.modifiers.shift and selected.anchor != selected.caret) {
                const range = selected.range();
                const a_line = ix.lineAt(&self.storage, root, range.start);
                const b_line = ix.lineAt(&self.storage, root, range.end);
                if (a_line != b_line) target = .{ .byte_offset = if (input.key == .left) range.start else range.end } else {
                    const a = try current.entry.layout.caret(.{ .byte_offset = try cache.snap(current.entry.layout, range.start - current.byte, false) });
                    const b = try current.entry.layout.caret(.{ .byte_offset = try cache.snap(current.entry.layout, range.end - current.byte, true), .affinity = .upstream });
                    target = .{ .byte_offset = if ((a.y < b.y or (a.y == b.y and a.x < b.x)) == (input.key == .left)) range.start else range.end };
                }
            } else if (try visualStep(current.entry, caret, rect, input.key == .right, current.byte != 0)) |next| {
                target = next;
                target.byte_offset += current.byte;
            } else target = try neighbor(self, current, input.key == .left, if (input.key == .left) 1000000 else -1000000);
        },
        .home, .end => {
            preferred_x = null;
            const native_line = cache.lineAt(try current.entry.layout.lines(), rect.y + rect.height * 0.5);
            var found = false;
            for (current.entry.stops) |stop| {
                if (stop.line != native_line or (current.byte != 0 and stop.caret.byte_offset == 0 and stop.caret.affinity == .upstream)) continue;
                target = try cache.hitTest(current.entry, .{ .x = stop.rect.x, .y = stop.rect.y + stop.rect.height * 0.5 }, current.byte != 0);
                found = true;
                if (input.key == .home) break;
            }
            if (!found) return error.InvalidParagraphMetrics;
            target.byte_offset += current.byte;
        },
        .up, .down, .page_up, .page_down => {
            const x = preferred_x orelse rect.x;
            preferred_x = x;
            const amount = if (input.key == .up or input.key == .down) rect.height else @max(rect.height, bounds.height - rect.height);
            const delta: f64 = if (input.key == .up or input.key == .page_up) -amount else amount;
            if ((input.key == .page_up or input.key == .page_down) and activeGeometry(self) != null) target = try projectedPageTarget(self, current, line, rect, x, delta, shape_start) else target = try verticalTarget(self, current, x, @as(f64, rect.y) + rect.height * 0.5 + delta, shape_start);
        },
        else => unreachable,
    }
    if (ix.get(&self.storage, root, ix.lineAt(&self.storage, root, target.byte_offset)).hidden and (input.key == .home or input.key == .end)) {
        target = .{ .byte_offset = current.byte + try current.entry.layout.graphemeByte(try current.entry.layout.graphemeCount() - 1), .affinity = .upstream };
    } else if (ix.get(&self.storage, root, ix.lineAt(&self.storage, root, target.byte_offset)).hidden) {
        const backwards = input.key == .left or input.key == .up or input.key == .page_up or input.key == .home;
        target = try neighbor(self, current, backwards, if (backwards) 1000000 else -1000000);
    }
    return .{ .selected = .{ .anchor = if (input.modifiers.shift) selected.anchor else target.byte_offset, .caret = target.byte_offset }, .affinity = target.affinity, .preferred_x = preferred_x };
}
fn moveSelections(self: *State, input: z.KeyInput, bounds: Rect) !void {
    const selected = try self.document.selections(self.selection_buffer);
    const movements = try self.allocator().alloc(Movement, selected.items.len);
    defer self.allocator().free(movements);
    const shape_start = self.total_bytes;
    for (selected.items, movements, 0..) |item, *movement, at| {
        movement.* = try moveOne(self, item, self.affinityAt(at, selected.primary), self.preferredAt(at, selected.primary), input, bounds, shape_start);
        movement.primary = at == selected.primary;
        if (self.total_bytes - shape_start > self.limits.shaped_bytes) return error.ShapeBudgetExceeded;
    }
    try self.publishMovement(movements, selected.primary);
}
fn keyInput(self: *State, window: z.Window, input: z.KeyInput, bounds: Rect, parameters: Parameters) !bool {
    if (self.token == null or input.modifiers.alt or input.modifiers.super or try self.document.composition() != null) return false;
    const control = input.modifiers.control;
    const key = input.key;
    if (control) switch (key) {
        .a => {
            _ = try self.select(.{ .anchor = 0, .caret = try self.document.byteLength() }, .downstream);
            try updateAfterInput(self, window, bounds, parameters);
            return true;
        },
        .z, .y => {
            _ = try self.undo(key == .y or input.modifiers.shift);
            try updateAfterInput(self, window, bounds, parameters);
            return true;
        },
        .home, .end => {
            const selected = try self.document.selection();
            const target = if (key == .home) 0 else try self.document.byteLength();
            if (input.modifiers.shift and try self.document.selectionCount() > 1) {
                const all = try self.document.selections(self.selection_buffer);
                const movements = try self.allocator().alloc(Movement, all.items.len);
                defer self.allocator().free(movements);
                for (all.items, movements, 0..) |item, *movement, at| movement.* = .{ .selected = .{ .anchor = item.anchor, .caret = target }, .affinity = .downstream, .preferred_x = null, .primary = at == all.primary };
                try self.publishMovement(movements, all.primary);
                try updateAfterInput(self, window, bounds, parameters);
                return true;
            }
            _ = try self.select(.{ .anchor = if (input.modifiers.shift) selected.anchor else target, .caret = target }, .downstream);
            // Explicit navigation reveals its endpoint even if an earlier
            // edit already put selection there and the viewport later moved.
            self.reveal = true;
            self.layout_required = true;
            try updateAfterInput(self, window, bounds, parameters);
            return true;
        },
        else => return false,
    };
    switch (key) {
        .enter, .tab => {
            if (key == .tab and input.modifiers.shift) return false;
            _ = try self.replaceSelections(if (key == .enter) "\n" else "\t", false);
            try updateAfterInput(self, window, bounds, parameters);
            return true;
        },
        .left, .right, .up, .down, .home, .end, .page_up, .page_down, .backspace, .delete => {},
        else => return false,
    }
    if ((key == .backspace or key == .delete) and try self.document.selectionCount() > 1) {
        try deleteSelections(self, key == .backspace);
        try updateAfterInput(self, window, bounds, parameters);
        return true;
    }
    self.reveal = true;
    self.layout_required = true;
    try updateAfterInput(self, window, bounds, parameters);
    if (try self.document.selectionCount() > 1) {
        try moveSelections(self, input, bounds);
        try updateAfterInput(self, window, bounds, parameters);
        return true;
    }
    if (self.folds != null and key != .backspace and key != .delete) {
        const movement = try moveOne(self, try self.document.selection(), self.affinity, self.preferred_x, input, bounds, self.total_bytes);
        self.preferred_x = movement.preferred_x;
        _ = try self.select(movement.selected, movement.affinity);
        try updateAfterInput(self, window, bounds, parameters);
        return true;
    }
    const selected = try self.document.selection();
    const root = try self.currentIndex();
    const line = caretLine(self, root, selected.caret);
    const current = try probe(self, line);
    defer current.close();
    const local = try cache.snap(current.entry.layout, selected.caret - current.byte, true);
    const caret: t.Caret = .{ .byte_offset = local, .affinity = self.affinity };
    const rect = try current.entry.layout.caret(caret);
    var target: t.Caret = .{ .byte_offset = selected.caret, .affinity = self.affinity };
    if (key == .backspace or key == .delete) {
        var range = selected.range();
        const first = try probe(self, ix.lineAt(&self.storage, root, range.start));
        defer first.close();
        const last = try probe(self, ix.lineAt(&self.storage, root, range.end));
        defer last.close();
        range.start = first.byte + try cache.snap(first.entry.layout, range.start - first.byte, false);
        range.end = last.byte + try cache.snap(last.entry.layout, range.end - last.byte, true);
        if (range.start == range.end) {
            const at = try graphemeIndex(current.entry.layout, local);
            if (key == .backspace) {
                if (at > 0) range.start = current.byte + try current.entry.layout.graphemeByte(at - 1) else if (current.first != 0) {
                    const previous = try probe(self, current.first - 1);
                    defer previous.close();
                    const previous_end = try graphemeIndex(previous.entry.layout, selected.caret - previous.byte);
                    range.start = previous.byte + try previous.entry.layout.graphemeByte(previous_end - 1);
                }
            } else if (at < try current.entry.layout.graphemeCount()) range.end = current.byte + try current.entry.layout.graphemeByte(at + 1);
        }
        if (range.start != range.end) _ = try self.replace(range, "", false);
        self.preferred_x = null;
    } else {
        switch (key) {
            .left, .right => {
                self.preferred_x = null;
                if (!input.modifiers.shift and selected.anchor != selected.caret) {
                    const range = selected.range();
                    const a_line = ix.lineAt(&self.storage, root, range.start);
                    const b_line = ix.lineAt(&self.storage, root, range.end);
                    if (a_line != b_line) {
                        target = .{ .byte_offset = if (key == .left) range.start else range.end };
                    } else {
                        const a = try current.entry.layout.caret(.{ .byte_offset = try cache.snap(current.entry.layout, range.start - current.byte, false) });
                        const b = try current.entry.layout.caret(.{ .byte_offset = try cache.snap(current.entry.layout, range.end - current.byte, true), .affinity = .upstream });
                        target = .{ .byte_offset = if ((a.y < b.y or (a.y == b.y and a.x < b.x)) == (key == .left)) range.start else range.end };
                    }
                } else if (try visualStep(current.entry, caret, rect, key == .right, current.byte != 0)) |next| {
                    target = next;
                    target.byte_offset += current.byte;
                } else target = try neighbor(self, current, key == .left, if (key == .left) 1000000 else -1000000);
            },
            .home, .end => {
                self.preferred_x = null;
                const native_line = cache.lineAt(try current.entry.layout.lines(), rect.y + rect.height * 0.5);
                if (key == .home) {
                    for (current.entry.stops) |stop| if (stop.line == native_line) {
                        target = try cache.hitTest(current.entry, .{ .x = stop.rect.x, .y = stop.rect.y + stop.rect.height * 0.5 }, current.byte != 0);
                        break;
                    };
                } else {
                    var at = current.entry.stops.len;
                    while (at > 0) {
                        at -= 1;
                        if (current.entry.stops[at].line == native_line) {
                            const stop = current.entry.stops[at];
                            target = try cache.hitTest(current.entry, .{ .x = stop.rect.x, .y = stop.rect.y + stop.rect.height * 0.5 }, current.byte != 0);
                            break;
                        }
                    }
                }
                target.byte_offset += current.byte;
            },
            .up, .down => {
                const x = self.preferred_x orelse rect.x;
                self.preferred_x = x;
                const y = rect.y + rect.height * 0.5 + (if (key == .down) rect.height else -rect.height);
                const last_row = current.entry.row_count - 1;
                const bottom = current.entry.tops[last_row] + current.entry.heights[last_row];
                if (y < 0 or y >= bottom) target = try neighbor(self, current, key == .up, x) else {
                    target = try cache.hitTest(current.entry, .{ .x = x, .y = y }, current.byte != 0);
                    target.byte_offset += current.byte;
                }
            },
            .page_up, .page_down => {
                const x = self.preferred_x orelse rect.x;
                self.preferred_x = x;
                const previous = self.view.?.caret orelse return error.CaretNotVisible;
                _ = try scrollState(self, .{ .x = 0, .y = (if (key == .page_down) @as(f32, 1) else -1) * @max(1, bounds.height - rect.height) });
                try updateAfterInput(self, window, bounds, parameters);
                target = try hit(self, &self.view.?, .{ .x = bounds.x + x - @as(f32, @floatCast(self.scroll_x)), .y = previous.y + previous.height * 0.5 });
            },
            else => unreachable,
        }
        _ = try self.select(.{ .anchor = if (input.modifiers.shift) selected.anchor else target.byte_offset, .caret = target.byte_offset }, target.affinity);
    }
    try updateAfterInput(self, window, bounds, parameters);
    return true;
}

fn fontEqual(a: t.Options, b: t.Options) bool {
    return a.size == b.size and a.weight == b.weight and a.italic == b.italic and a.width == b.width and a.wrap == b.wrap and a.direction == b.direction and a.word_ranges == b.word_ranges and std.mem.eql(u8, a.family, b.family) and std.mem.eql(u8, a.locale, b.locale);
}
fn validBounds(bounds: Rect) !void {
    if (!ui.layout.validRect(bounds) or bounds.width <= 0 or bounds.height <= 0 or bounds.width > 1000000 or bounds.height > 1000000) return error.InvalidGeometry;
}
fn difference(a: u128, b: u128) f64 {
    return if (a >= b) @as(f64, @floatFromInt(a - b)) / ix.units else -@as(f64, @floatFromInt(b - a)) / ix.units;
}
fn intraTicks(value: f64) u128 {
    return @intFromFloat(@floor(@max(0, value) * ix.units));
}
fn shiftTicks(offset: u128, delta: f64, total: u128, viewport: f64) u128 {
    const change = @round(delta * ix.units);
    const magnitude: u128 = @intFromFloat(@abs(change));
    const raw = if (change < 0) offset -| magnitude else offset +| magnitude;
    const viewport_ticks: u128 = @intFromFloat(@ceil(viewport * ix.units));
    return @min(raw, total -| viewport_ticks);
}
fn activeGeometry(self: *State) ?*projection.Geometry {
    const plan = self.projected_plan orelse return null;
    if (!(plan.current() catch false) or (self.document.composition() catch return null) != null or self.projected_fold_version != self.fold_version) return null;
    const value = if (self.projected_geometry) |*geometry_value| geometry_value else return null;
    return if (value.plan == plan) value else null;
}
fn projectedPrefix(self: *State, root: *ix.Node, geometry_value: ?*const projection.Geometry, line: usize) u128 {
    return ix.prefix(&self.storage, root, line).ticks + if (geometry_value) |value| value.prefix(&self.storage, line) else 0;
}
fn anchorShift(self: *State, root: *ix.Node, anchor: Anchor, delta: f64, viewport: f64) Anchor {
    return anchorShiftUsing(self, root, activeGeometry(self), anchor, delta, viewport);
}
fn anchorShiftUsing(self: *State, root: *ix.Node, geometry_value: ?*const projection.Geometry, anchor: Anchor, delta: f64, viewport: f64) Anchor {
    const local = anchor.intra + delta;
    const prefix = projectedPrefix(self, root, geometry_value, anchor.line);
    const total = root.sum.ticks + if (geometry_value) |value| value.total() else 0;
    const signed_ticks = @floor(local * ix.units);
    const magnitude: u128 = @intFromFloat(@abs(signed_ticks));
    const viewport_ticks: u128 = @intFromFloat(@ceil(@min(viewport, @as(f64, @floatFromInt(total)) / ix.units) * ix.units));
    const maximum = total - @min(total, viewport_ticks);
    const raw = if (signed_ticks < 0) prefix -| magnitude else prefix +| magnitude;
    const target = @min(maximum, raw);
    const line = if (geometry_value) |value| value.atTick(&self.storage, root, target) else ix.atTick(&self.storage, root, target);
    var intra = difference(target, projectedPrefix(self, root, geometry_value, line));
    if (target != maximum and !(signed_ticks < 0 and magnitude > prefix)) intra += local - signed_ticks / ix.units;
    return .{ .line = line, .id = ix.get(&self.storage, root, line).id, .intra = intra };
}
fn relative(self: *State, root: *ix.Node, line: usize, anchor: Anchor) f64 {
    return difference(ix.prefix(&self.storage, root, line).ticks, ix.prefix(&self.storage, root, anchor.line).ticks) - anchor.intra;
}
const Working = struct {
    state: *State,
    folds: ?*folding.Set = null,
    root: *ix.Node,
    anchor: Anchor,
    scroll_x: f64 = 0,
    entries: [max_batches]?*cache.Entry = @splat(null),
    count: usize = 0,
    view: View,
    generation: u64,
    font: t.Options,
    parameters: Parameters,
    shaped: usize = 0,
    bytes: usize = 0,
    allow_hidden: bool = false,
    projected: ?projection.Geometry = null,
    projected_intra: u128 = 0,
    reveal: bool = false,
    fn close(self: *Working) void {
        self.view.close(self.state.allocator());
        for (self.entries[0..self.count]) |entry| entry.?.release();
        ix.release(&self.state.storage, self.root);
        folding.release(self.folds);
        if (self.projected) |*geometry_value| geometry_value.close(&self.state.storage);
    }
    fn cached(self: *Working, line: usize, allow_prefix: bool) ?struct { entry: *cache.Entry, first: usize } {
        const state = self.state;
        const row = ix.get(&state.storage, self.root, line);
        var all: [max_batches * 2]?*cache.Entry = @splat(null);
        @memcpy(all[0..self.count], self.entries[0..self.count]);
        @memcpy(all[self.count..][0..state.entry_count], state.entries[0..state.entry_count]);
        for (all[0 .. self.count + state.entry_count]) |maybe| {
            const entry = maybe.?;
            for (entry.rows[0..entry.row_count], 0..) |record, offset| {
                if (record.id != row.id or offset > line) continue;
                const first = line - offset;
                if ((!allow_prefix and first != line)) continue;
                if (entry.matches(&state.storage, self.root, first, self.generation)) return .{ .entry = entry, .first = first };
            }
        }
        return null;
    }
    fn load(self: *Working, line: usize, allow_prefix: bool) !struct { entry: *cache.Entry, first: usize } {
        const state = self.state;
        const hidden_endpoint = ix.get(&state.storage, self.root, line).hidden;
        if (hidden_endpoint and !self.allow_hidden) return error.CaretInsideFold;
        const found = self.cached(line, allow_prefix);
        var entry: *cache.Entry = undefined;
        var first: usize = undefined;
        if (found) |value| {
            entry = value.entry.retain();
            first = value.first;
        } else {
            if (self.count == state.limits.batches) return error.VisibleCapacityExceeded;
            first = line;
            var rows: [cache.max_rows]ix.Row = undefined;
            var count: usize = 0;
            var bytes: usize = 0;
            while (first + count < self.root.sum.rows and count < state.limits.batch_rows) {
                const row = ix.get(&state.storage, self.root, first + count);
                if ((row.hidden and !hidden_endpoint) or (hidden_endpoint and count != 0)) break;
                if (row.bytes > state.limits.paragraph_bytes) return error.ParagraphCapacityExceeded;
                if (count != 0 and row.bytes > state.limits.batch_bytes -| bytes) break;
                if (row.bytes > state.limits.paragraph_bytes -| bytes) break;
                rows[count] = row;
                bytes += row.bytes;
                count += 1;
            }
            if (bytes > state.limits.shaped_bytes -| self.bytes) return error.ShapeBudgetExceeded;
            const text = try state.allocator().alloc(u8, bytes);
            defer state.allocator().free(text);
            const start = ix.prefix(&state.storage, self.root, first).bytes;
            try state.readDisplay(.{ .start = start, .end = start + bytes }, text);
            entry = try cache.create(state.budget, state.engine, text, rows[0..count], self.font, self.generation, state.limits.visual_stops);
            self.bytes += bytes;
            self.shaped += 1;
            state.total_batches +|= 1;
            state.total_bytes +|= bytes;
        }
        var duplicate = false;
        for (self.entries[0..self.count]) |owned| if (owned.? == entry) {
            duplicate = true;
            break;
        };
        if (duplicate) {
            entry.release();
        } else {
            if (self.count == state.limits.batches) {
                entry.release();
                return error.VisibleCapacityExceeded;
            }
            self.entries[self.count] = entry;
            self.count += 1;
        }
        for (entry.heights[0..entry.row_count], 0..) |height_value, offset| {
            const row = ix.get(&state.storage, self.root, first + offset);
            const ticks = try ix.quantize(height_value);
            if (!row.measured or row.metric_generation != self.generation or row.ticks != ticks) {
                const next = try ix.height(&state.storage, self.root, first + offset, ticks, self.generation);
                ix.release(&state.storage, self.root);
                self.root = next;
            }
            if (self.projected) |*geometry_value| try geometry_value.update(&state.storage, self.root, first + offset);
        }
        return .{ .entry = entry, .first = first };
    }
    fn top(self: *Working, line: usize) u128 {
        return ix.prefix(&self.state.storage, self.root, line).ticks + if (self.projected) |*value| value.prefix(&self.state.storage, line) else 0;
    }
    fn textTop(self: *Working, line: usize) u128 {
        return self.top(line) + if (self.projected) |*value| value.gap(line) else 0;
    }
    fn relativeText(self: *Working, line: usize) f64 {
        if (self.projected != null) return difference(self.textTop(line), self.top(self.anchor.line) + self.projected_intra);
        return difference(self.textTop(line), self.top(self.anchor.line)) - self.anchor.intra;
    }
    fn prepared(self: *Working, entry: *cache.Entry, viewport: t.drawing.Rect) !*cache.Prepared {
        const state = self.state;
        if (state.view) |*old| for (old.blocks[0..old.count]) |block| {
            if (block.entry == entry and block.prepared.scale == self.parameters.scale and std.meta.eql(block.prepared.viewport, viewport)) return block.prepared.retain();
        };
        return cache.prepare(state.budget, entry, self.parameters.scale, viewport, state.limits.prepared);
    }
};
fn appendMarks(self: *State, marks: *std.ArrayList(Mark), layout: *const t.Layout, range: d.Range, origin: Point, bounds: Rect, kind: @FieldType(Mark, "kind")) !void {
    if (range.start == range.end) return;
    const selected: t.ByteRange = .{ .start = try cache.snap(layout, range.start, false), .end = try cache.snap(layout, range.end, true) };
    const count = try layout.selectionRectCount(selected);
    if (count > self.limits.rectangles -| marks.items.len) return error.RectangleCapacityExceeded;
    const storage = try self.allocator().alloc(t.Rect, count);
    defer self.allocator().free(storage);
    for (try layout.selectionRects(selected, storage)) |item| {
        var rect: Rect = .{ .x = origin.x + item.x, .y = origin.y + item.y, .width = item.width, .height = item.height };
        if (kind == .composition) {
            rect.y += @max(0, rect.height - 1);
            rect.height = 1;
        }
        rect = ui.layout.intersect(rect, bounds);
        if (rect.width > 0 and rect.height > 0) try marks.append(self.allocator(), .{ .rect = rect, .kind = kind });
    }
}
fn geometry(work: *Working) !void {
    const state = work.state;
    const selected = try state.allSelections();
    const composition = try state.document.composition();
    var marks: std.ArrayList(Mark) = .empty;
    defer marks.deinit(state.allocator());
    var carets: std.ArrayList(CaretMark) = .empty;
    defer carets.deinit(state.allocator());
    var headers: std.ArrayList(FoldHeaderMark) = .empty;
    defer headers.deinit(state.allocator());
    var seen: [64]u64 = @splat(0);
    var runs: RunIterator = .{ .view = &work.view };
    while (try runs.next()) |run| {
        const block = run.block;
        const origin: Point = .{ .x = work.view.bounds.x - @as(f32, @floatCast(work.scroll_x)), .y = @floatCast(@as(f64, work.view.bounds.y) + run.y) };
        for (selected.items, 0..) |item, selection_index| {
            const range = item.range();
            if (range.start < run.range.end and range.end > run.range.start) try appendMarks(state, &marks, block.entry.layout, .{ .start = @max(range.start, run.range.start) - block.byte, .end = @min(range.end, run.range.end) - block.byte }, origin, run.clip, .selection);
            const affinity = state.affinityAt(selection_index, selected.primary);
            if (!caretInRun(work, run, item.caret, affinity)) continue;
            const mask = @as(u64, 1) << @intCast(selection_index % 64);
            if (seen[selection_index / 64] & mask != 0) continue;
            seen[selection_index / 64] |= mask;
            const byte = try cache.snap(block.entry.layout, item.caret - block.byte, true);
            const native = try block.entry.layout.caret(.{ .byte_offset = byte, .affinity = affinity });
            const rect: Rect = .{ .x = @floatCast(@as(f64, work.view.bounds.x) + native.x - work.scroll_x), .y = origin.y + native.y, .width = @max(1, native.width), .height = native.height };
            if (selection_index == selected.primary) work.view.caret = rect;
            if (ui.layout.intersect(rect, run.clip).width > 0 and ui.layout.intersect(rect, run.clip).height > 0) try carets.append(state.allocator(), .{ .selection = selection_index, .primary = selection_index == selected.primary, .rect = rect });
        }
        if (composition) |value| {
            const marked: d.Range = .{ .start = value.range.start, .end = value.range.start + value.text.len };
            if (marked.start < run.range.end and marked.end > run.range.start) try appendMarks(state, &marks, block.entry.layout, .{ .start = @max(marked.start, run.range.start) - block.byte, .end = @min(marked.end, run.range.end) - block.byte }, origin, run.clip, .composition);
        }
    }
    runs.at = 0;
    if (work.folds) |set| while (try runs.next()) |run| {
        const block = run.block;
        var lo: usize = 0;
        var hi = set.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (set.entries[mid].fold.header < run.range.start) lo = mid + 1 else hi = mid;
        }
        while (lo < set.entries.len and set.entries[lo].fold.header < run.range.end) : (lo += 1) {
            const entry = set.entries[lo];
            if (entry.first - 1 < block.line or entry.first - 1 >= block.line + block.entry.row_count) continue;
            const offset = entry.first - 1 - block.line;
            const rect: Rect = .{ .x = work.view.bounds.x, .y = @floatCast(@as(f64, work.view.bounds.y) + run.y + block.entry.tops[offset]), .width = work.view.bounds.width, .height = @floatCast(block.entry.heights[offset]) };
            if (ui.layout.intersect(rect, work.view.bounds).height > 0) try headers.append(state.allocator(), .{ .id = entry.fold.id, .collapsed = entry.fold.collapsed, .rect = rect });
        }
    };
    var transferred = false;
    const owned_headers = try headers.toOwnedSlice(state.allocator());
    errdefer if (!transferred) state.allocator().free(owned_headers);
    const owned_marks = try marks.toOwnedSlice(state.allocator());
    errdefer if (!transferred) state.allocator().free(owned_marks);
    work.view.carets = try carets.toOwnedSlice(state.allocator());
    work.view.marks = owned_marks;
    work.view.headers = owned_headers;
    transferred = true;
    if (work.parameters.caret_cells) try prepareCaretCells(work);
}

fn caretInRun(work: *Working, run: VisualRun, byte: usize, affinity: t.Affinity) bool {
    return if (run.paragraph) |line| line == paragraphFor(work.state, work.root, byte, affinity) else byte >= run.range.start and (byte < run.range.end or (byte == run.range.end and (run.last or affinity == .upstream)));
}
/// This frame-sized scratch exists only for explicit caret-cell preparation.
fn prepareCaretCells(work: *Working) !void {
    const state = work.state;
    if (try state.document.version() != work.view.revision) return error.StaleRevision;
    const selected = try state.allSelections();
    var visuals: std.ArrayList(CaretVisual) = .empty;
    defer visuals.deinit(state.allocator());
    var cells: std.ArrayList(caret_visual.Rect) = .empty;
    defer cells.deinit(state.allocator());
    var indexes: [max_batches]?caret_visual.Index = @splat(null);
    defer for (&indexes) |*index| if (index.*) |*owned| owned.close(state.allocator());
    var cell_work: caret_visual.Work = .{ .remaining = state.limits.caret_work };
    var seen: [64]u64 = @splat(0);
    var runs: RunIterator = .{ .view = &work.view };
    while (try runs.next()) |run| {
        const block = run.block;
        const origin: Point = .{ .x = work.view.bounds.x - @as(f32, @floatCast(work.scroll_x)), .y = @floatCast(@as(f64, work.view.bounds.y) + run.y) };
        for (selected.items, 0..) |item, selection_index| {
            const affinity = state.affinityAt(selection_index, selected.primary);
            if (!caretInRun(work, run, item.caret, affinity)) continue;
            const mask = @as(u64, 1) << @intCast(selection_index % 64);
            if (seen[selection_index / 64] & mask != 0) continue;
            seen[selection_index / 64] |= mask;
            try cell_work.take(1);
            const byte = try cache.snap(block.entry.layout, item.caret - block.byte, true);
            const native = try block.entry.layout.caret(.{ .byte_offset = byte, .affinity = affinity });
            const insertion: Rect = .{ .x = @floatCast(@as(f64, work.view.bounds.x) + native.x - work.scroll_x), .y = origin.y + native.y, .width = @max(1, native.width), .height = native.height };
            var slot: usize = 0;
            while (work.view.blocks[slot].entry != block.entry) : (slot += 1) {}
            const spans = try block.entry.layout.advanceSpans();
            if (indexes[slot] == null) indexes[slot] = try caret_visual.Index.init(state.allocator(), spans, &cell_work);
            const first = cells.items.len;
            const gi = try graphemeIndex(block.entry.layout, byte);
            if (gi < try block.entry.layout.graphemeCount()) {
                var query = try indexes[slot].?.query(spans, byte, try block.entry.layout.graphemeByte(gi + 1), cache.lineAt(try block.entry.layout.lines(), native.y + native.height * 0.5), native.x, &cell_work);
                while (try query.next(spans, &cell_work)) |cell| {
                    if (cells.items.len == state.limits.rectangles) return error.RectangleCapacityExceeded;
                    try cells.append(state.allocator(), .{ .x = origin.x + cell.x, .y = origin.y + cell.y, .width = cell.width, .height = cell.height });
                }
            }
            try visuals.append(state.allocator(), .{ .native = insertion, .clip = run.clip, .first = first, .count = cells.items.len - first, .collapsed = item.anchor == item.caret });
        }
    }
    var rectangles = work.view.marks.len;
    for (visuals.items) |visual| {
        const needed = @max(@as(usize, 1), visual.count) * 4;
        if (needed > state.limits.rectangles -| rectangles) return error.RectangleCapacityExceeded;
        rectangles += needed;
    }
    const owned_visuals = try visuals.toOwnedSlice(state.allocator());
    errdefer state.allocator().free(owned_visuals);
    work.view.caret_cells = try cells.toOwnedSlice(state.allocator());
    work.view.caret_visuals = owned_visuals;
    work.view.cells_enabled = true;
}

fn copyLineBackgrounds(view: *const View, definitions: []const LineBackground, destination: ?[]LineBackgroundMark) !usize {
    var count: usize = 0;
    var runs: RunIterator = .{ .view = view };
    while (try runs.next()) |run| {
        const block = run.block;
        var byte = block.byte;
        const first = if (run.paragraph) |line| line - block.line else 0;
        const end = if (run.paragraph != null) first + 1 else block.entry.row_count;
        for (block.entry.rows[0..first]) |row| byte += row.bytes;
        for (first..end) |offset| {
            const at = line_backgrounds.lowerBound(definitions, byte);
            if (at < definitions.len and definitions[at].paragraph == byte) {
                const rect = ui.layout.intersect(.{ .x = view.bounds.x, .y = @floatCast(@as(f64, view.bounds.y) + run.y + block.entry.tops[offset]), .width = view.bounds.width, .height = @floatCast(block.entry.heights[offset]) }, run.clip);
                if (rect.width > 0 and rect.height > 0) {
                    if (destination) |items| items[count] = .{ .paragraph = byte, .color = definitions[at].color, .rect = rect };
                    count += 1;
                }
            }
            byte += block.entry.rows[offset].bytes;
        }
    }
    return count;
}
fn prepareLineBackgrounds(work: *Working) !void {
    const state = work.state;
    if (state.line_backgrounds.len == 0 or state.background_text_version != try state.document.committedTextVersion() or try state.document.composition() != null) return;
    const count = try copyLineBackgrounds(&work.view, state.line_backgrounds, null);
    if (count > state.limits.rectangles) return error.RectangleCapacityExceeded;
    const marks = try state.allocator().alloc(LineBackgroundMark, count);
    errdefer state.allocator().free(marks);
    _ = try copyLineBackgrounds(&work.view, state.line_backgrounds, marks);
    work.view.line_backgrounds = marks;
}

fn prepareRangeMarkers(work: *Working) !void {
    const state = work.state;
    work.view.range_marker_version = state.range_marker_version;
    if (state.range_markers.len == 0 or state.marker_text_version != try state.document.committedTextVersion() or try state.document.composition() != null) return;
    var effort: range_markers.Work = .{ .remaining = state.limits.range_marker_work };
    var marks: std.ArrayList(RangeMarkerMark) = .empty;
    defer marks.deinit(state.allocator());
    var scratch: std.ArrayList(t.Rect) = .empty;
    defer scratch.deinit(state.allocator());
    var clips: std.ArrayList(TextClip) = .empty;
    defer clips.deinit(state.allocator());
    var foreground = false;
    for (state.range_markers) |entry| if (entry.marker.kind == .foreground) {
        foreground = true;
        break;
    };
    var run_index: u32 = 0;
    var run_marks: usize = 0;
    var runs: RunIterator = .{ .view = &work.view };
    while (try runs.next()) |run| {
        // Charge a conservative binary-search upper bound, even when this run
        // has no overlap. Default empty metadata never enters this function.
        try effort.take(1 + std.math.log2_int(usize, state.range_markers.len));
        var at = range_markers.firstOverlap(state.range_markers, run.range.start);
        while (at < state.range_markers.len and state.range_markers[at].marker.range.start < run.range.end) : (at += 1) {
            try effort.take(1);
            const marker = state.range_markers[at].marker;
            const local = try rangeInRun(run, marker.range) orelse continue;
            const layout = run.block.entry.layout;
            // selectionRectCount scans cached spans once; selectionRects scans
            // them twice (capacity + output). No native query is performed.
            try effort.take(3 * (try layout.advanceSpans()).len);
            const needed = try layout.selectionRectCount(local);
            if (needed > state.limits.rectangles) return error.RectangleCapacityExceeded;
            try scratch.resize(state.allocator(), needed);
            for (try layout.selectionRects(local, scratch.items)) |item| {
                try effort.take(1);
                var decorated = item;
                if (marker.kind == .underline) {
                    decorated.height = @min(item.height, marker.thickness);
                    decorated.y += item.height - decorated.height;
                }
                // Form the decoration before clipping. A partly hidden cell
                // must not acquire a replacement underline at the clip edge.
                const rect = rangeRect(&work.view, work.scroll_x, run, decorated);
                if (rect.width == 0 or rect.height == 0) continue;
                if (marks.items.len == state.limits.rectangles) return error.RectangleCapacityExceeded;
                try marks.append(state.allocator(), .{ .marker = at, .range = marker.range, .kind = marker.kind, .color = marker.color, .rect = rect });
            }
        }
        if (foreground) try appendTextClips(state, &clips, run, run_index, marks.items[run_marks..]);
        run_index += 1;
        run_marks = marks.items.len;
    }
    const owned_clips = try clips.toOwnedSlice(state.allocator());
    errdefer state.allocator().free(owned_clips);
    work.view.range_markers = try marks.toOwnedSlice(state.allocator());
    work.view.text_clips = owned_clips;
}

/// The clips of one run's text pass: each foreground marker rectangle in its
/// color, and the rest of the run, cut into strips between the rectangles'
/// edges, in the text color. Prepared once per layout so paint only replays.
fn appendTextClips(state: *State, clips: *std.ArrayList(TextClip), run: VisualRun, run_index: u32, marks: []const RangeMarkerMark) !void {
    const allocator = state.allocator();
    const area = run.clip;
    if (area.width <= 0 or area.height <= 0) return;
    var edges: std.ArrayList(f32) = .empty;
    defer edges.deinit(allocator);
    var spans: std.ArrayList([2]f32) = .empty;
    defer spans.deinit(allocator);
    try edges.append(allocator, area.y);
    try edges.append(allocator, area.y + area.height);
    for (marks) |mark| if (mark.kind == .foreground) {
        try clips.append(allocator, .{ .rect = mark.rect, .color = mark.color, .run = run_index });
        try edges.append(allocator, std.math.clamp(mark.rect.y, area.y, area.y + area.height));
        try edges.append(allocator, std.math.clamp(mark.rect.y + mark.rect.height, area.y, area.y + area.height));
    };
    std.mem.sort(f32, edges.items, {}, std.sort.asc(f32));
    var at: usize = 0;
    while (at + 1 < edges.items.len) : (at += 1) {
        const top = edges.items[at];
        const bottom = edges.items[at + 1];
        if (bottom <= top) continue;
        // Horizontal extents of the markers covering this whole strip.
        spans.clearRetainingCapacity();
        for (marks) |mark| if (mark.kind == .foreground and mark.rect.y <= top and mark.rect.y + mark.rect.height >= bottom and mark.rect.width > 0) {
            try spans.append(allocator, .{ mark.rect.x, mark.rect.x + mark.rect.width });
        };
        std.mem.sort([2]f32, spans.items, {}, struct {
            fn less(_: void, a: [2]f32, b: [2]f32) bool {
                return a[0] < b[0];
            }
        }.less);
        var x = area.x;
        const right = area.x + area.width;
        for (spans.items) |span| {
            if (span[0] > x) try clips.append(allocator, .{ .rect = .{ .x = x, .y = top, .width = @min(span[0], right) - x, .height = bottom - top }, .color = null, .run = run_index });
            x = @max(x, span[1]);
            if (x >= right) break;
        }
        if (x < right) try clips.append(allocator, .{ .rect = .{ .x = x, .y = top, .width = right - x, .height = bottom - top }, .color = null, .run = run_index });
        if (clips.items.len > 4 * state.limits.rectangles) return error.RectangleCapacityExceeded;
    }
}

/// The text pass with foreground markers: each run's prepared text once per
/// clip, in the clip's color.
fn drawClippedText(state: *State, view: *const View, frame: *ui.Frame, bounds: Rect, text: ui.Color) !void {
    var runs: RunIterator = .{ .view = view };
    var index: u32 = 0;
    var at: usize = 0;
    while (try runs.next()) |run| : (index += 1) {
        while (at < view.text_clips.len and view.text_clips[at].run < index) at += 1;
        const origin: ui.layout.Point = .{ .x = bounds.x - @as(f32, @floatCast(state.scroll_x)), .y = @floatCast(@as(f64, bounds.y) + run.y) };
        const prepared = try run.block.prepared.value.view();
        while (at < view.text_clips.len and view.text_clips[at].run == index) : (at += 1) {
            const clip = view.text_clips[at];
            if (clip.rect.width <= 0 or clip.rect.height <= 0) continue;
            try frame.pushClip(clip.rect);
            defer frame.popClip() catch |err| {
                frame.failure = frame.failure orelse err;
            };
            try frame.preparedText(origin, prepared, if (clip.color) |rgb| ui.Color.rgb(rgb) else text);
        }
        if (frame.context.window) |window| if (window.isClosed()) return error.Closed;
    }
}

fn fillView(work: *Working) !void {
    if (work.projected != null) return fillProjected(work);
    const self = work.state;
    const bounds = work.view.bounds;
    var line = work.anchor.line;
    while (line < work.root.sum.rows) {
        const loaded = try work.load(line, work.view.count == 0);
        const height_value = @as(f64, @floatFromInt(ix.get(&self.storage, work.root, work.anchor.line).ticks)) / ix.units;
        work.anchor.intra = std.math.clamp(work.anchor.intra, 0, @max(0, height_value - 1.0 / ix.units));
        const y = relative(self, work.root, loaded.first, work.anchor);
        const viewport: t.drawing.Rect = .{ .x = @floatCast(work.scroll_x - 16), .y = @floatCast(-y - 16), .width = bounds.width + 32, .height = bounds.height + 32 };
        const prepared = try work.prepared(loaded.entry, viewport);
        work.view.blocks[work.view.count] = .{ .entry = loaded.entry.retain(), .prepared = prepared, .line = loaded.first, .byte = ix.prefix(&self.storage, work.root, loaded.first).bytes, .y = y };
        work.view.count += 1;
        line = ix.nextVisible(&self.storage, work.root, loaded.first + loaded.entry.row_count) orelse work.root.sum.rows;
        if (line == work.root.sum.rows or relative(self, work.root, line, work.anchor) >= bounds.height) break;
    }
}
fn fillProjected(work: *Working) !void {
    const self = work.state;
    const bounds = work.view.bounds;
    var placements: std.ArrayList(ParagraphPlacement) = .empty;
    defer placements.deinit(self.allocator());
    var line = work.anchor.line;
    while (line < work.root.sum.rows) {
        const loaded = try work.load(line, work.view.count == 0);
        if (work.view.count == max_batches) return error.VisibleCapacityExceeded;
        const row_end = work.top(work.anchor.line + 1);
        const row_start = work.top(work.anchor.line);
        work.projected_intra = @min(work.projected_intra, (row_end - row_start) -| 1);
        work.anchor.intra = @as(f64, @floatFromInt(work.projected_intra)) / ix.units;
        const first_byte = ix.prefix(&self.storage, work.root, loaded.first).bytes;
        var byte = first_byte;
        var viewport: ?t.drawing.Rect = null;
        for (loaded.entry.rows[0..loaded.entry.row_count], 0..) |record, offset| {
            const source_line = loaded.first + offset;
            const y = work.relativeText(source_line);
            const native_top = loaded.entry.tops[offset];
            const height = loaded.entry.heights[offset];
            if (!ix.get(&self.storage, work.root, source_line).hidden) {
                if (placements.items.len == max_batches * cache.max_rows) return error.VisibleCapacityExceeded;
                try placements.append(self.allocator(), .{ .block = work.view.count, .line = source_line, .range = .{ .start = byte, .end = byte + record.bytes }, .native_top = native_top, .y = y, .height = height });
                const top = @max(0, -y);
                const bottom = @min(height, bounds.height - y);
                if (bottom > top) {
                    const begin = native_top + top;
                    const end = native_top + bottom;
                    if (viewport) |*value| {
                        const maximum = @max(@as(f64, value.y) + value.height, end);
                        value.y = @floatCast(@min(value.y, begin));
                        value.height = @floatCast(maximum - value.y);
                    } else viewport = .{ .x = @floatCast(work.scroll_x - 16), .y = @floatCast(begin), .width = bounds.width + 32, .height = @floatCast(end - begin) };
                }
            }
            byte += record.bytes;
        }
        const coverage = viewport orelse t.drawing.Rect{ .x = @floatCast(work.scroll_x), .y = 0, .width = 1, .height = 1 };
        const prepared = try work.prepared(loaded.entry, coverage);
        work.view.blocks[work.view.count] = .{ .entry = loaded.entry.retain(), .prepared = prepared, .line = loaded.first, .byte = first_byte, .y = work.relativeText(loaded.first) - loaded.entry.tops[0] };
        work.view.count += 1;
        line = ix.nextVisible(&self.storage, work.root, loaded.first + loaded.entry.row_count) orelse work.root.sum.rows;
        if (line == work.root.sum.rows or difference(work.top(line), work.top(work.anchor.line) + work.projected_intra) >= bounds.height) break;
    }
    work.view.placements = try placements.toOwnedSlice(self.allocator());
}
const LayoutCandidate = struct {
    state: *State,
    work: ?Working = null,
    old_view: ?View = null,
    font: OwnedFont = .{},
    view_version: u64 = 0,
    projection_version: u64 = 0,
    revision: u64 = 0,
    suppress_projection: bool = false,
    defer_layout: bool = false,
    rebuilt: bool = false,
    pending_plan: ?*projection.Plan = null,
    replace_plan: bool = false,
    published: bool = false,
    fold_override: ?*const FoldCandidate = null,
    fn close(self: *LayoutCandidate) void {
        if (self.old_view) |*view| view.close(self.state.allocator());
        self.old_view = null;
        if (self.work) |*work| work.close();
        self.work = null;
        if (self.pending_plan) |plan| plan.releaseClient();
        self.pending_plan = null;
    }
    fn validate(self: *LayoutCandidate) !void {
        if (self.revision != try self.state.document.version()) return error.StaleRevision;
    }
    /// Move both sides of every ownership edge before releasing anything. This
    /// phase has no allocator/native/user calls and keeps the caller's Busy pin.
    fn publish(self: *LayoutCandidate) void {
        std.debug.assert(!self.published);
        const work = if (self.work) |*value| value else return;
        const state = self.state;
        std.mem.swap(?View, &self.old_view, &state.view);
        state.view = work.view;
        work.view.count = 0;
        work.view.marks = &.{};
        work.view.carets = &.{};
        work.view.caret_visuals = &.{};
        work.view.caret_cells = &.{};
        work.view.headers = &.{};
        work.view.placements = &.{};
        work.view.line_backgrounds = &.{};
        work.view.range_markers = &.{};
        work.view.text_clips = &.{};
        std.mem.swap([max_batches]?*cache.Entry, &state.entries, &work.entries);
        std.mem.swap(usize, &state.entry_count, &work.count);
        if (state.overlay != null) {
            std.mem.swap(*ix.Node, &state.overlay.?, &work.root);
            std.mem.swap(?*folding.Set, &state.overlay_folds, &work.folds);
        } else {
            std.mem.swap(*ix.Node, &state.committed.?, &work.root);
            std.mem.swap(?*folding.Set, &state.folds, &work.folds);
            state.fold_version = state.view.?.fold_version;
        }
        state.anchor = work.anchor;
        state.scroll_x = work.scroll_x;
        state.font = self.font;
        state.generation = work.generation;
        state.mask_shaped = state.masked;
        state.view_version = self.view_version;
        state.projection_version = self.projection_version;
        state.parameters_version = work.parameters.version;
        state.caret_cells = work.parameters.caret_cells;
        state.scale = work.parameters.scale;
        state.estimate = work.parameters.estimated_height;
        state.bounds = state.view.?.bounds;
        state.configured = true;
        state.layout_required = false;
        state.last_layout_error = null;
        state.reveal = false;
        if (work.projected != null) state.projected_intra = work.projected_intra;
        std.mem.swap(?projection.Geometry, &state.projected_geometry, &work.projected);
        if (self.replace_plan) std.mem.swap(?*projection.Plan, &state.projected_plan, &self.pending_plan);
        state.projected_fold_version = state.view.?.fold_version;
        self.published = true;
    }
};

const FoldCandidate = struct {
    state: *State,
    revision: u64,
    root: ?*ix.Node = null,
    folds: ?*folding.Set = null,
    old_root: ?*ix.Node = null,
    old_folds: ?*folding.Set = null,
    fn version(self: *const FoldCandidate) u64 {
        return self.state.fold_version + @intFromBool(self.root != null);
    }
    fn close(self: *FoldCandidate) void {
        const root = self.root;
        const folds = self.folds;
        const old_root = self.old_root;
        const old_folds = self.old_folds;
        self.root = null;
        self.folds = null;
        self.old_root = null;
        self.old_folds = null;
        ix.release(&self.state.storage, root);
        folding.release(folds);
        ix.release(&self.state.storage, old_root);
        folding.release(old_folds);
    }
    fn construct(self: *FoldCandidate, definitions: []const Fold) !void {
        const state = self.state;
        if (try state.document.version() != self.revision) return error.StaleRevision;
        try state.synchronize();
        if (definitions.len != 0 and try state.document.composition() != null) return error.CompositionActive;
        if (definitions.len == 0 and state.folds == null) return;
        if (state.fold_version == std.math.maxInt(u64)) return error.IdExhausted;
        self.folds = try folding.create(state.allocator(), &state.storage, state.committed.?, definitions, state.limits.folds);
        try self.validate();
        const selected = try state.document.selections(state.selection_buffer);
        if (self.folds) |set| for (selected.items) |item| if (set.hidden(ix.lineAt(&state.storage, state.committed.?, item.caret))) return error.CaretInsideFold;
        self.root = try folding.apply(&state.storage, state.committed.?, state.folds, self.folds);
        try self.validate();
    }
    fn validate(self: *FoldCandidate) !void {
        if (try self.state.document.version() != self.revision) return error.StaleRevision;
    }
    /// No allocation, release or user/native call between the two publications.
    fn publish(self: *FoldCandidate) void {
        if (self.root == null) return;
        const state = self.state;
        std.mem.swap(?*ix.Node, &state.committed, &self.root);
        std.mem.swap(?*folding.Set, &state.folds, &self.folds);
        std.mem.swap(?*ix.Node, &self.root, &self.old_root);
        std.mem.swap(?*folding.Set, &self.folds, &self.old_folds);
        state.fold_version += 1;
        state.layout_required = true;
        state.normalizeAnchor();
    }
};

/// Atomically publish two borrowed fold layers, then release old roots while
/// both Adapters and the Window are pinned. Empty layers may clear a composing
/// pair; nonempty layers require committed document coordinates. Unknown
/// external revisions require an explicit reindex before this transaction.
pub fn setFoldsPair(window: z.Window, tokens: [2]FoldToken, revisions: [2]u64, definitions: [2][]const Fold) !FoldPairResult {
    const left = try tokens[0].adapter.state();
    const right = try tokens[1].adapter.state();
    if (left == right) return error.SameAdapter;
    if (left.fold_owner != tokens[0].generation or right.fold_owner != tokens[1].generation) return error.StaleFoldToken;
    try boundWindow(left, window);
    try boundWindow(right, window);
    const scope = window.beginCallback() orelse return error.Closed;
    defer scope.end();
    left.busy = true;
    right.busy = true;
    defer {
        left.busy = false;
        right.busy = false;
    }
    var first: FoldCandidate = .{ .state = left, .revision = revisions[0] };
    defer first.close();
    var second: FoldCandidate = .{ .state = right, .revision = revisions[1] };
    defer second.close();
    first.construct(definitions[0]) catch |err| return left.budget.normalize(err);
    if (window.isClosed()) return error.Closed;
    second.construct(definitions[1]) catch |err| return right.budget.normalize(err);
    if (window.isClosed()) return error.Closed;
    try first.validate();
    try second.validate();
    first.publish();
    second.publish();
    first.close();
    second.close();
    const failure = foldPairError(window, left, right, revisions);
    return .{ .current = failure == null, .post_publish_error = failure };
}
fn foldPairError(window: z.Window, left: *State, right: *State, revisions: [2]u64) ?anyerror {
    if (window.isClosed()) return error.Closed;
    const a = left.document.version() catch |err| return err;
    const b = right.document.version() catch |err| return err;
    return if (a != revisions[0] or b != revisions[1]) error.StaleRevision else null;
}

pub const ParagraphMetric = struct { line: usize, range: d.Range, height: f64, terminated: bool };
pub const ProjectionAnchor = struct { line: usize, intra_ticks: u128 = 0 };
/// Borrowed only for the synchronous PairPlanner callback. Methods can load
/// bounded whole paragraphs through the candidate's ordinary native cache.
/// No method, pointer or copy may be used after that callback returns.
pub const LayoutProbe = opaque {
    fn work(self: *LayoutProbe) !*Working {
        const value: *Working = @ptrCast(@alignCast(self));
        if (value.state.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!value.state.busy) return error.ProbeClosed;
        return value;
    }
    pub fn sourceDocument(self: *LayoutProbe) !*d.Document {
        return (try self.work()).state.document;
    }
    pub fn lineCount(self: *LayoutProbe) !usize {
        return (try self.work()).root.sum.rows;
    }
    pub fn paragraph(self: *LayoutProbe, line: usize) !ParagraphMetric {
        const value = try self.work();
        if (line >= value.root.sum.rows) return error.InvalidLine;
        const loaded = try value.load(line, true);
        const row = ix.get(&value.state.storage, value.root, line);
        const start = ix.prefix(&value.state.storage, value.root, line).bytes;
        return .{ .line = line, .range = .{ .start = start, .end = start + row.bytes }, .height = loaded.entry.heights[line - loaded.first], .terminated = row.terminated };
    }
};
/// Plans remain host-owned. Successful publication adds Adapter client pins;
/// failure takes no ownership. scroll_ticks uses 2^-32 DIP integer units to
/// avoid adding a tiny viewport to a large absolute floating-point position.
pub const PairProjection = struct { plans: [2]?*projection.Plan, scroll_ticks: ?u128 = null, anchors: ?[2]ProjectionAnchor = null };
pub const PairPlanner = struct {
    context: *anyopaque,
    build: *const fn (*anyopaque, [2]*LayoutProbe) anyerror!PairProjection,
    /// Final owner authority, including projection-suspended composition.
    /// Runs before either pure ownership swap; it borrows no geometry probes.
    validate: ?*const fn (*anyopaque) anyerror!void = null,
    /// Optional final candidate inspection, after both native layouts finish
    /// and before any ownership swap. Borrowed probes must not escape it.
    prepared: ?*const fn (*anyopaque, [2]*PreparedProbe) anyerror!void = null,
};
/// Read-only, nonallocating geometry of a completed candidate. This shares the
/// exact range/caret implementation with the published Adapter queries. A
/// probe is borrowed ONLY during PairPlanner.prepared, never after it returns.
pub const PreparedProbe = opaque {
    fn candidate(self: *PreparedProbe) !*LayoutCandidate {
        const value: *LayoutCandidate = @ptrCast(@alignCast(self));
        if (value.state.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!value.state.busy or value.work == null) return error.ProbeClosed;
        if (value.revision != try value.state.document.version()) return error.StaleRevision;
        if (try value.state.document.composition() != null) return error.CompositionActive;
        return value;
    }
    pub fn revision(self: *PreparedProbe) !u64 {
        return (try self.candidate()).revision;
    }
    pub fn projectionVersion(self: *PreparedProbe) !u64 {
        return (try self.candidate()).projection_version;
    }
    pub fn rangeRects(self: *PreparedProbe, expected_revision: u64, range: d.Range, destination: []t.Rect) ![]const t.Rect {
        const value = try self.candidate();
        if (expected_revision != value.revision) return error.StaleRevision;
        try value.state.validateRange(range);
        const work = &value.work.?;
        return preparedRangeRects(&work.view, work.scroll_x, range, destination);
    }
    pub fn positionRect(self: *PreparedProbe, expected_revision: u64, position: usize, affinity: t.Affinity) !?t.Rect {
        const value = try self.candidate();
        if (expected_revision != value.revision) return error.StaleRevision;
        try value.state.validateRange(.{ .start = position, .end = position });
        const work = &value.work.?;
        return preparedPositionRect(value.state, &work.view, work.root, work.scroll_x, position, affinity);
    }
};
pub const ProjectPairResult = struct { sides: [2]PrepareResult, projection_suspended: bool, current: bool, post_publish_error: ?anyerror };
pub const PairFolds = struct { tokens: [2]FoldToken, revisions: [2]u64, definitions: [2][]const Fold };

fn installCandidatePlan(candidate: *LayoutCandidate, plan: ?*projection.Plan, offset: ?u128, anchor: ?ProjectionAnchor) !void {
    const state = candidate.state;
    const work = &candidate.work.?;
    if (plan) |next| {
        if (next.document != state.document) return error.ForeignDocument;
        if (!try next.current()) return error.StaleRevision;
        try next.retainClient();
    }
    candidate.replace_plan = true;
    candidate.pending_plan = plan;
    const reusable = if (work.projected) |*old| old.plan == plan else false;
    if (!reusable) {
        if (work.projected) |*old| old.close(&state.storage);
        work.projected = null;
        if (plan) |next| work.projected = try projection.Geometry.create(&state.storage, work.root, next);
    }
    work.view.projected = work.projected != null;
    if (plan) |next| {
        work.projected_intra = if (next == state.projected_plan) state.projected_intra orelse intraTicks(work.anchor.intra) else intraTicks(work.anchor.intra);
    }
    if (offset) |requested| {
        work.reveal = false;
        const total = work.root.sum.ticks + if (work.projected) |*value| value.total() else 0;
        const target = @min(requested, total -| 1);
        const line = if (work.projected) |*value| value.atTick(&state.storage, work.root, target) else ix.atTick(&state.storage, work.root, target);
        const intra = target - work.top(line);
        work.anchor = .{ .line = line, .id = ix.get(&state.storage, work.root, line).id, .intra = @as(f64, @floatFromInt(intra)) / ix.units };
        work.projected_intra = intra;
    }
    if (anchor) |requested| {
        work.reveal = false;
        if (requested.line >= work.root.sum.rows or ix.get(&state.storage, work.root, requested.line).hidden) return error.InvalidProjection;
        work.anchor = .{ .line = requested.line, .id = ix.get(&state.storage, work.root, requested.line).id, .intra = @as(f64, @floatFromInt(requested.intra_ticks)) / ix.units };
        work.projected_intra = requested.intra_ticks;
    }
}

/// Measure, derive a paired placement plan, then publish both visible layouts.
/// Any composition suspends BOTH projections and skips planner build/prepared;
/// the final planner validation still runs before publication. The host
/// hides derived comparison decoration during that temporary identity view.
pub fn projectPair(window: z.Window, a: *Adapter, b: *Adapter, bounds: [2]Rect, parameters: [2]Parameters, planner: PairPlanner) !ProjectPairResult {
    return projectPairInner(window, a, b, bounds, parameters, planner, null);
}
/// Fold roots, native layout and paired Plans publish at the same pure point.
/// Prepublication error changes neither fold version nor visible viewport.
pub fn projectPairWithFolds(window: z.Window, a: *Adapter, b: *Adapter, bounds: [2]Rect, parameters: [2]Parameters, planner: PairPlanner, folds: PairFolds) !ProjectPairResult {
    if (folds.tokens[0].adapter != a or folds.tokens[1].adapter != b) return error.ForeignFoldToken;
    return projectPairInner(window, a, b, bounds, parameters, planner, folds);
}
fn projectPairInner(window: z.Window, a: *Adapter, b: *Adapter, bounds: [2]Rect, parameters: [2]Parameters, planner: PairPlanner, folds: ?PairFolds) !ProjectPairResult {
    const left = try a.state();
    const right = try b.state();
    if (left.pre_input_running or right.pre_input_running) return error.Busy;
    if (left == right) return error.SameAdapter;
    try boundWindow(left, window);
    try boundWindow(right, window);
    const composing = try left.document.composition() != null or try right.document.composition() != null;
    if (composing and folds == null) {
        const outcome = try preparePairGuarded(window, a, b, bounds, parameters, planner.context, planner.validate);
        return .{ .sides = outcome.sides, .projection_suspended = true, .current = outcome.current, .post_publish_error = outcome.post_publish_error };
    }
    const scope = window.beginCallback() orelse return error.Closed;
    defer scope.end();
    left.busy = true;
    right.busy = true;
    defer {
        left.busy = false;
        right.busy = false;
    }
    var fold_a: FoldCandidate = .{ .state = left, .revision = if (folds) |value| value.revisions[0] else 0 };
    defer fold_a.close();
    var fold_b: FoldCandidate = .{ .state = right, .revision = if (folds) |value| value.revisions[1] else 0 };
    defer fold_b.close();
    if (folds) |value| {
        if (left.fold_owner != value.tokens[0].generation or right.fold_owner != value.tokens[1].generation) return error.StaleFoldToken;
        fold_a.construct(value.definitions[0]) catch |err| return left.budget.normalize(err);
        fold_b.construct(value.definitions[1]) catch |err| return right.budget.normalize(err);
        if (window.isClosed()) return error.Closed;
    }
    var first: LayoutCandidate = .{ .state = left, .defer_layout = true, .suppress_projection = composing, .fold_override = if (folds != null) &fold_a else null };
    defer first.close();
    var second: LayoutCandidate = .{ .state = right, .defer_layout = true, .suppress_projection = composing, .fold_override = if (folds != null) &fold_b else null };
    defer second.close();
    _ = constructView(&first, bounds[0], parameters[0]) catch |err| return left.budget.normalize(err);
    _ = constructView(&second, bounds[1], parameters[1]) catch |err| return right.budget.normalize(err);
    const plan = if (!composing) try planner.build(planner.context, .{ @ptrCast(&first.work.?), @ptrCast(&second.work.?) }) else PairProjection{ .plans = @splat(null) };
    if (plan.scroll_ticks != null and plan.anchors != null) return error.InvalidProjection;
    if (window.isClosed()) return error.Closed;
    try first.validate();
    try second.validate();
    if (!composing) {
        installCandidatePlan(&first, plan.plans[0], plan.scroll_ticks, if (plan.anchors) |values| values[0] else null) catch |err| return left.budget.normalize(err);
        installCandidatePlan(&second, plan.plans[1], plan.scroll_ticks, if (plan.anchors) |values| values[1] else null) catch |err| return right.budget.normalize(err);
    }
    const x = completeView(&first) catch |err| return left.budget.normalize(err);
    const y = completeView(&second) catch |err| return right.budget.normalize(err);
    if (!composing) if (planner.prepared) |callback| try callback(planner.context, .{ @ptrCast(&first), @ptrCast(&second) });
    if (window.isClosed()) return error.Closed;
    try first.validate();
    try second.validate();
    if (planner.validate) |validate| {
        try validate(planner.context);
        if (window.isClosed()) return error.Closed;
        try first.validate();
        try second.validate();
    }
    if (folds != null) {
        try fold_a.validate();
        try fold_b.validate();
        fold_a.publish();
        fold_b.publish();
    }
    first.publish();
    second.publish();
    first.close();
    second.close();
    fold_a.close();
    fold_b.close();
    const failure = publishedPairError(window, left, right, first.revision, second.revision);
    return .{ .sides = .{ x, y }, .projection_suspended = composing, .current = failure == null, .post_publish_error = failure };
}

fn publishedPairError(window: z.Window, left: *State, right: *State, a_revision: u64, b_revision: u64) ?anyerror {
    var failure: ?anyerror = null;
    left.synchronize() catch |err| {
        failure = err;
    };
    right.synchronize() catch |err| {
        failure = failure orelse err;
    };
    if (window.isClosed()) return failure orelse error.Closed;
    // These final reads are pure: no native/allocator callback can change the
    // opposite side between the two full revision observations.
    if ((left.document.version() catch unreachable) != a_revision or (right.document.version() catch unreachable) != b_revision) return failure orelse error.StaleRevision;
    if (left.layout_required or right.layout_required) return failure orelse error.LayoutRequired;
    return failure;
}

fn prepareView(self: *State, bounds: Rect, parameters: Parameters) !PrepareResult {
    var candidate: LayoutCandidate = .{ .state = self };
    defer candidate.close();
    const result = try constructView(&candidate, bounds, parameters);
    try candidate.validate();
    candidate.publish();
    candidate.close();
    try self.synchronize();
    return result;
}

/// Synchronous two-Adapter presentation transaction. Both Adapters stay Busy
/// through construction, both pure ownership swaps and old-resource disposal.
/// The host still owns text/history and must keep its Window callback context
/// alive through this call. No extra allocation is made by the transaction.
pub fn preparePair(window: z.Window, a: *Adapter, b: *Adapter, bounds: [2]Rect, parameters: [2]Parameters) !PairResult {
    return preparePairGuarded(window, a, b, bounds, parameters, null, null);
}
fn preparePairGuarded(window: z.Window, a: *Adapter, b: *Adapter, bounds: [2]Rect, parameters: [2]Parameters, context: ?*anyopaque, validate: ?*const fn (*anyopaque) anyerror!void) !PairResult {
    const left = try a.state();
    const right = try b.state();
    if (left.pre_input_running or right.pre_input_running) return error.Busy;
    if (left == right) return error.SameAdapter;
    try boundWindow(left, window);
    try boundWindow(right, window);
    const scope = window.beginCallback() orelse return error.Closed;
    defer scope.end();
    left.busy = true;
    right.busy = true;
    defer {
        left.busy = false;
        right.busy = false;
    }
    var first: LayoutCandidate = .{ .state = left };
    defer first.close();
    var second: LayoutCandidate = .{ .state = right };
    defer second.close();
    const composing = try left.document.composition() != null or try right.document.composition() != null;
    first.suppress_projection = composing;
    second.suppress_projection = composing;
    const x = constructView(&first, bounds[0], parameters[0]) catch |err| return left.budget.normalize(err);
    const y = constructView(&second, bounds[1], parameters[1]) catch |err| return right.budget.normalize(err);
    if (window.isClosed()) return error.Closed;
    try first.validate();
    try second.validate();
    if (validate) |callback| {
        try callback(context.?);
        if (window.isClosed()) return error.Closed;
        try first.validate();
        try second.validate();
    }
    first.publish();
    second.publish();
    first.close();
    second.close();
    const failure = publishedPairError(window, left, right, first.revision, second.revision);
    return .{ .sides = .{ x, y }, .current = failure == null, .post_publish_error = failure };
}

fn constructView(candidate: *LayoutCandidate, bounds: Rect, parameters: Parameters) !PrepareResult {
    const self = candidate.state;
    if (self.pre_input_running) return error.Busy;
    try validBounds(bounds);
    if (!std.math.isFinite(parameters.scale) or parameters.scale <= 0 or parameters.scale > 16 or !std.math.isFinite(parameters.estimated_height) or parameters.estimated_height <= 0 or parameters.font.family.len > 255 or parameters.font.locale.len > 127) return error.InvalidParameters;
    _ = try ix.quantize(parameters.estimated_height);
    self.budget.denied = false;
    self.synchronize() catch |err| if (err != error.IndexRequired and (err != error.FoldIndexRequired or !self.pending_fold_restore)) return err;
    if (self.pending_fold_restore) try self.restoreFolds();
    const rebuilt = self.index_required;
    if (rebuilt) try self.reindex();
    if (self.folds_required) return error.FoldIndexRequired;
    var font = parameters.font;
    if (font.wrap != .none) font.width = bounds.width;
    const same = self.configured and parameters.version == self.parameters_version and fontEqual(font, self.font.get()) and self.mask_shaped == self.masked;
    candidate.revision = self.observed;
    const want_projected = if (self.projected_plan) |plan| !candidate.suppress_projection and try plan.current() and try self.document.composition() == null else false;
    if (self.view) |*view| try view.ensureUnused();
    if (!candidate.defer_layout and same and !self.layout_required and parameters.caret_cells == self.caret_cells and parameters.scale == self.scale and std.meta.eql(bounds, self.bounds) and self.view.?.projected == want_projected) {
        self.estimate = parameters.estimated_height;
        self.last_layout_error = null;
        return .{ .changed = false, .shaped_batches = 0, .shaped_bytes = 0, .index_rebuilt = rebuilt };
    }
    const generation = if (same) self.generation else std.math.add(u64, self.generation, 1) catch return error.IdExhausted;
    const view_version = std.math.add(u64, self.view_version, 1) catch return error.IdExhausted;
    candidate.view_version = view_version;
    candidate.rebuilt = rebuilt;
    candidate.font.set(font);
    const source_root = if (self.overlay != null) self.overlay.? else if (candidate.fold_override) |value| value.root orelse self.committed.? else try self.currentIndex();
    const source_folds = if (self.overlay != null) self.overlay_folds else if (candidate.fold_override) |value| if (value.root != null) value.folds else self.folds else self.folds;
    candidate.work = .{ .state = self, .folds = folding.retain(source_folds), .root = ix.retain(source_root).?, .anchor = self.anchor, .scroll_x = self.scroll_x, .view = .{ .bounds = bounds, .scale = parameters.scale, .revision = self.observed }, .generation = generation, .font = candidate.font.get(), .parameters = parameters, .reveal = self.reveal };
    const work = &candidate.work.?;
    if (self.fold_owner != null) {
        if (self.overlay != null) {
            try self.validateFoldCaretsIn(work.root, &.{try self.selection()});
        } else try self.validateFoldCaretsIn(work.root, (try self.document.selections(self.selection_buffer)).items);
    }
    if (self.reveal and self.overlay == null and self.fold_owner == null) {
        const expanded = try folding.expanded(self.allocator(), &self.storage, work.root, work.folds, (try self.selection()).caret, self.limits.folds);
        if (expanded != work.folds) {
            if (self.fold_version == std.math.maxInt(u64)) {
                folding.release(expanded);
                return error.IdExhausted;
            }
            const root = folding.apply(&self.storage, work.root, work.folds, expanded) catch |err| {
                folding.release(expanded);
                return err;
            };
            ix.release(&self.storage, work.root);
            work.root = root;
        }
        folding.release(work.folds);
        work.folds = expanded;
    }
    if (ix.get(&self.storage, work.root, work.anchor.line).hidden) {
        work.anchor.line = ix.previousVisible(&self.storage, work.root, work.anchor.line) orelse ix.nextVisible(&self.storage, work.root, work.anchor.line).?;
        work.anchor.id = ix.get(&self.storage, work.root, work.anchor.line).id;
        work.anchor.intra = 0;
    }
    if (self.projected_plan) |plan| if (want_projected) {
        work.projected = if (self.projected_geometry) |*previous| if (previous.plan == plan and self.projected_fold_version == self.fold_version and work.folds == self.folds) previous.retain() else try projection.Geometry.create(&self.storage, work.root, plan) else try projection.Geometry.create(&self.storage, work.root, plan);
        work.projected_intra = self.projected_intra orelse intraTicks(work.anchor.intra);
        work.view.projected = true;
    };
    if (candidate.defer_layout) return .{ .changed = true, .shaped_batches = 0, .shaped_bytes = 0, .index_rebuilt = rebuilt };
    return completeView(candidate);
}
fn completeView(candidate: *LayoutCandidate) !PrepareResult {
    const self = candidate.state;
    const work = &candidate.work.?;
    const bounds = work.view.bounds;
    const parameters = work.parameters;
    const generation = work.generation;
    var finished = false;
    for (0..self.limits.batches + 1) |_| {
        work.view.close(self.allocator());
        work.view.count = 0;
        work.view.marks = &.{};
        work.view.carets = &.{};
        work.view.caret_visuals = &.{};
        work.view.caret_cells = &.{};
        work.view.headers = &.{};
        work.view.placements = &.{};
        work.view.line_backgrounds = &.{};
        work.view.range_markers = &.{};
        work.view.text_clips = &.{};
        work.view.caret = null;
        if (work.reveal) {
            const selected = try self.selection();
            const target_line = caretLine(self, work.root, selected.caret);
            const loaded = try work.load(target_line, true);
            const start = ix.prefix(&self.storage, work.root, loaded.first).bytes;
            const caret = try loaded.entry.layout.caret(.{ .byte_offset = try cache.snap(loaded.entry.layout, selected.caret - start, true), .affinity = self.affinity });
            if (caret.height > bounds.height) return error.ViewportTooShort;
            if (@max(1, caret.width) > bounds.width) return error.ViewportTooNarrow;
            const right = bounds.width - @max(1, caret.width);
            if (caret.x < work.scroll_x) work.scroll_x = @max(0, caret.x) else if (caret.x > work.scroll_x + right) work.scroll_x = @max(0, @as(f64, caret.x) - right);
            if (work.scroll_x > max_scroll_x) return error.HorizontalCapacityExceeded;
            const gap = if (work.projected) |*value| @as(f64, @floatFromInt(value.gap(target_line))) / ix.units else 0;
            const y = work.relativeText(target_line) + caret.y - loaded.entry.tops[target_line - loaded.first];
            const bottom = @max(0, bounds.height - caret.height - 1 / parameters.scale);
            if (y < 0 or y > bottom) {
                const desired_y = std.math.clamp(y, 0, bottom);
                if (work.projected) |*value| {
                    const raw = work.textTop(target_line) + intraTicks(@as(f64, caret.y) - loaded.entry.tops[target_line - loaded.first]);
                    const target = shiftTicks(raw -| intraTicks(desired_y), 0, work.root.sum.ticks + value.total(), bounds.height);
                    const at = value.atTick(&self.storage, work.root, target);
                    work.projected_intra = target - work.top(at);
                    work.anchor = .{ .line = at, .id = ix.get(&self.storage, work.root, at).id, .intra = @as(f64, @floatFromInt(work.projected_intra)) / ix.units };
                } else work.anchor = anchorShiftUsing(self, work.root, null, .{ .line = target_line, .id = ix.get(&self.storage, work.root, target_line).id }, gap + @as(f64, caret.y) - loaded.entry.tops[target_line - loaded.first] - desired_y, bounds.height);
            }
        }
        try fillView(work);
        try geometry(work);
        if (!work.reveal) {
            finished = true;
            break;
        }
        if (work.view.caret) |caret| if (caret.y >= bounds.y and caret.y + caret.height <= bounds.y + bounds.height and caret.x >= bounds.x and caret.x + caret.width <= bounds.x + bounds.width) {
            finished = true;
            break;
        };
        // Measuring the visible rows can replace very inaccurate provisional
        // heights between anchor and caret. Re-evaluate against that exact
        // candidate index, within the same explicit layout/shape budgets.
    }
    if (!finished) return error.ShapeBudgetExceeded;
    try prepareLineBackgrounds(work);
    try prepareRangeMarkers(work);
    // Retain a bounded warm cache after the visible entries. This does not
    // construct layouts, mutate entries or keep historical document roots.
    for (self.entries[0..self.entry_count]) |maybe| {
        if (work.count == self.limits.batches) break;
        const entry = maybe.?;
        if (entry.generation != generation) continue;
        var found = false;
        for (work.entries[0..work.count]) |active| if (active.? == entry) {
            found = true;
            break;
        };
        if (!found) {
            work.entries[work.count] = entry.retain();
            work.count += 1;
        }
    }
    try self.synchronize();
    work.view.text_version = try self.document.committedTextVersion();
    work.view.composition_revision = if (try self.document.composition() != null) self.observed else null;
    work.view.geometry_generation = generation;
    work.view.fold_version = if (candidate.fold_override) |value| value.version() else std.math.add(u64, self.fold_version, @intFromBool(self.overlay == null and self.folds != work.folds)) catch return error.IdExhausted;
    work.view.scroll_x = work.scroll_x;
    work.view.projection_root = if (work.projected) |value| value.root else null;
    const same_projection = if (self.view) |*previous| projectionEqual(previous, &work.view) else false;
    const projection_version = if (same_projection) self.projection_version else std.math.add(u64, self.projection_version, 1) catch return error.IdExhausted;
    candidate.projection_version = projection_version;
    return .{ .changed = true, .shaped_batches = work.shaped, .shaped_bytes = work.bytes, .index_rebuilt = candidate.rebuilt };
}

test {
    _ = @import("presentation_lease.zig");
    _ = pointer_selection;
    _ = @import("pointer_selection_tests.zig");
    _ = @import("tests.zig");
    _ = password_mask;
    _ = projection;
    _ = owner_commands;
    _ = line_backgrounds;
    _ = range_markers;
}

test "complete Prepared hit is allocation free transactional and agrees with the original routes" {
    // This reference retains the pre-snapshot branch and tie expressions. It
    // reads the real system cache independently of both new reader adapters.
    const Reference = struct {
        fn cached(entry: *const cache.Entry, point: t.Point, previous: bool) !t.Caret {
            const native_lines = try entry.layout.lines();
            var li: usize = 0;
            while (li + 1 < native_lines.len and point.y >= native_lines[li].y + native_lines[li].height) : (li += 1) {}
            var first: usize = 0;
            while (first < entry.stops.len and entry.stops[first].line < li) : (first += 1) {}
            var end = first;
            while (end < entry.stops.len and entry.stops[end].line == li) : (end += 1) {}
            const omitted: ?usize = if (previous and entry.first_upstream >= first and entry.first_upstream < end) entry.first_upstream - first else null;
            const items = entry.stops[first..end];
            const count = items.len - @intFromBool(omitted != null);
            if (count == 0) return error.InvalidParagraphMetrics;
            var low: usize = 0;
            while (low < count and cacheStop(items, omitted, low).rect.x < point.x) : (low += 1) {}
            var selected = @min(low, count - 1);
            if (selected > 0 and @abs(@as(f64, cacheStop(items, omitted, selected - 1).rect.x) - point.x) <= @abs(@as(f64, cacheStop(items, omitted, selected).rect.x) - point.x)) selected -= 1;
            return cacheStop(items, omitted, selected).caret;
        }
        fn cacheStop(items: []const cache.Stop, omitted: ?usize, at: usize) cache.Stop {
            return items[at + @intFromBool(if (omitted) |value| at >= value else false)];
        }
        fn query(state: *State, view: *const View, point: Point) !t.Caret {
            var chosen = view.count - 1;
            var native_y: f32 = undefined;
            if (view.projected) {
                const local_y = @as(f64, point.y) - view.bounds.y;
                var best = std.math.inf(f64);
                var placement_index: usize = 0;
                for (view.placements, 0..) |item, at| {
                    const distance = if (local_y < item.y) item.y - local_y else @max(0, local_y - item.y - item.height);
                    if (distance < best) {
                        best = distance;
                        placement_index = at;
                    }
                }
                const item = view.placements[placement_index];
                chosen = item.block;
                native_y = @floatCast(item.native_top + local_y - item.y);
                if (local_y <= item.y or local_y >= item.y + item.height) {
                    var found = false;
                    for (try view.blocks[chosen].entry.layout.lines()) |line| {
                        const center = @as(f64, line.y) + @as(f64, line.height) * 0.5;
                        if (center < item.native_top or center >= item.native_top + item.height) continue;
                        native_y = @floatCast(center);
                        found = true;
                        if (local_y <= item.y) break;
                    }
                    if (!found) return error.InvalidParagraphMetrics;
                }
            } else {
                for (view.blocks[0..view.count], 0..) |item, at| {
                    const last = item.entry.row_count - 1;
                    if (point.y - view.bounds.y < item.y + (item.entry.tops[last] + item.entry.heights[last])) {
                        chosen = at;
                        break;
                    }
                }
                native_y = @floatCast(@as(f64, point.y) - view.bounds.y - view.blocks[chosen].y);
            }
            const block = view.blocks[chosen];
            var result = try cached(block.entry, .{ .x = @floatCast(@as(f64, point.x) - view.bounds.x + state.scroll_x), .y = native_y }, block.byte != 0);
            result.byte_offset += block.byte;
            if (!view.projected) {
                const root = try state.currentIndex();
                if (ix.get(&state.storage, root, ix.lineAt(&state.storage, root, result.byte_offset)).hidden) {
                    result.byte_offset = block.byte + try block.entry.layout.graphemeByte(try block.entry.layout.graphemeCount() - 1);
                    result.affinity = .upstream;
                }
            }
            return result;
        }
    };
    const before = t.resourceCounts();
    for (0..4) |scenario| {
        const engine = try t.Engine.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
        var engine_live = true;
        defer if (engine_live) engine.close() catch unreachable;
        const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), if (scenario == 3) "" else "aaaaaaaaaaaaaaaa\nאבג e\u{301}😀\r\nthird line\nhidden tail\n", .{});
        var document_live = true;
        defer if (document_live) document.close() catch unreachable;
        var plan: ?*ProjectionPlan = null;
        defer if (plan) |item| item.close() catch unreachable;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const adapter = try Adapter.create(failing.allocator(), document, engine, .{ .batch_rows = 1 });
        var adapter_live = true;
        defer if (adapter_live) adapter.close() catch unreachable;
        const bounds: Rect = .{ .x = -8.25, .y = 8.375, .width = 180.5, .height = 120.25 };
        const parameters: Parameters = .{ .font = .{ .size = 18, .wrap = .none, .width = bounds.width }, .scale = 1.25 };
        _ = try adapter.prepare(bounds, parameters);
        if (scenario == 1) {
            plan = try ProjectionPlan.create(std.testing.allocator, document, &.{ .{ .line = 1, .gap_before = 17.25, .minimum_height = 45 }, .{ .line = 2, .gap_before = 4.5 } }, .{});
            try adapter.setProjection(plan);
        } else if (scenario == 2) try adapter.setFolds(try document.version(), &.{.{ .id = 1, .header = 0, .end = try document.byteLength(), .collapsed = true }});
        _ = try adapter.scrollBy(.{ .x = 1.375, .y = 0 });
        _ = try adapter.prepare(bounds, parameters);
        var blocks = @as([24]HitBlock, @splat(.{ .first = 0, .count = 0, .y = 0, .end = 0 }));
        var lines = @as([128]HitLine, @splat(.{ .y = 0, .height = 1, .first = 0, .count = 0 }));
        var stops = @as([1024]HitStop, @splat(.{ .x = 0, .position = 0, .affinity = 0 }));
        var placements = @as([768]HitPlacement, @splat(.{ .block = 0, .y = 0, .native_top = 0, .height = 1 }));
        const buffers: PreparedHitBuffers = .{ .blocks = &blocks, .lines = &lines, .stops = &stops, .placements = &placements };
        const allocation_index = failing.alloc_index;
        failing.fail_index = allocation_index;
        const snapshot = try adapter.preparedHit(try document.version(), buffers);
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(allocation_index, failing.alloc_index);
        try prepared_hit.validate(&snapshot.packet, .{});
        const saved = .{ blocks, lines, stops, placements };
        for (0..4) |capacity| {
            if (capacity == 3 and snapshot.packet.placement_count == 0) continue;
            var short = buffers;
            switch (capacity) {
                0 => short.blocks = blocks[0..0],
                1 => short.lines = lines[0..0],
                2 => short.stops = stops[0..0],
                3 => short.placements = placements[0..0],
                else => unreachable,
            }
            try std.testing.expectError(error.HitCapacityExceeded, adapter.preparedHit(try document.version(), short));
            try std.testing.expectEqualDeep(saved, .{ blocks, lines, stops, placements });
        }
        try std.testing.expectError(error.StaleRevision, adapter.preparedHit((try document.version()) + 1, buffers));
        try std.testing.expectEqualDeep(saved, .{ blocks, lines, stops, placements });
        const state = try adapter.state();
        const work = state.limits.caret_work;
        state.limits.caret_work = 1;
        try std.testing.expectError(error.WorkLimit, adapter.preparedHit(try document.version(), buffers));
        const pass = try copyPreparedHit(state, &state.view.?, null, work);
        state.limits.caret_work = 2 * pass.work - 1;
        try std.testing.expectError(error.WorkLimit, adapter.preparedHit(try document.version(), buffers));
        state.limits.caret_work = work;
        try std.testing.expectEqualDeep(saved, .{ blocks, lines, stops, placements });
        for (0..41) |yi| for (0..49) |xi| {
            const point: Point = .{ .x = bounds.x + @as(f32, @floatFromInt(xi)) * (bounds.width - 1) / 48, .y = bounds.y + @as(f32, @floatFromInt(yi)) * (bounds.height - 1) / 40 };
            const expected = try Reference.query(state, &state.view.?, point);
            try std.testing.expectEqualDeep(expected, try adapter.hitTest(bounds, point));
            const actual = try prepared_hit.query(&snapshot.packet, .{ .x = point.x, .y = point.y });
            try std.testing.expectEqual(expected.byte_offset, actual.position);
            try std.testing.expectEqual(@as(u32, @backingInt(expected.affinity)), actual.affinity);
        };
        const retained = try prepared_hit.query(&snapshot.packet, .{ .x = bounds.x, .y = bounds.y });
        std.debug.print("Prepared hit capture scenario={d} blocks={d} lines={d} stops={d} placements={d} pass_work={d}; sizes State={d} Packet={d} PreparedHit={d} buffers={d}\n", .{ scenario, snapshot.packet.block_count, snapshot.packet.line_count, snapshot.packet.stop_count, snapshot.packet.placement_count, pass.work, @sizeOf(State), @sizeOf(HitPacket), @sizeOf(PreparedHit), @sizeOf(PreparedHitBuffers) });
        try document.setComposition("", .{ .anchor = 0, .caret = 0 });
        try std.testing.expectError(error.CompositionActive, adapter.preparedHit(try document.version(), buffers));
        try std.testing.expectEqualDeep(saved, .{ blocks, lines, stops, placements });
        try std.testing.expect(try document.cancelComposition());
        try std.testing.expectError(error.LayoutRequired, adapter.preparedHit(try document.version(), buffers));
        try std.testing.expectEqualDeep(saved, .{ blocks, lines, stops, placements });
        try adapter.close();
        adapter_live = false;
        if (plan) |item| try item.close();
        plan = null;
        try document.close();
        document_live = false;
        try engine.close();
        engine_live = false;
        try std.testing.expectEqualDeep(retained, try prepared_hit.query(&snapshot.packet, .{ .x = bounds.x, .y = bounds.y }));
    }
    try std.testing.expectEqualDeep(before, t.resourceCounts());
}
