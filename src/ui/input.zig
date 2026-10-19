const std = @import("std");
const z = @import("ziggurat");
const affine_state = @import("affine_state.zig");
const affine = affine_state.affine;
pub const shortcut_scopes = @import("shortcut_scopes.zig");
pub const pointer_clicks = @import("pointer_click_workspace.zig");
pub const text_fields = @import("text_field_workspace.zig");

pub const Rect = z.Rect;
pub const ValueChange = union(enum) { set: f64, steps: i32, pages: i32, minimum, maximum };
pub const Values = struct { low: f64, high: f64 };
pub const Range = struct {
    minimum: f64,
    maximum: f64,
    /// Zero permits continuous pointer input; keyboard uses one percent.
    step: f64 = 0,
    page_step: ?f64 = null,
    pub fn validate(self: Range) error{InvalidRange}!void {
        if (!std.math.isFinite(self.minimum) or !std.math.isFinite(self.maximum) or self.maximum < self.minimum or !std.math.isFinite(self.maximum - self.minimum) or !std.math.isFinite(self.step) or self.step < 0) return error.InvalidRange;
        if (self.page_step) |page| if (!std.math.isFinite(page) or page <= 0) return error.InvalidRange;
    }
    pub fn validateValue(self: Range, value: f64) error{InvalidValue}!void {
        if (!std.math.isFinite(value) or value < self.minimum or value > self.maximum) return error.InvalidValue;
    }
    pub fn smallChange(self: Range) f64 {
        if (self.step > 0) return self.step;
        const span = self.maximum - self.minimum;
        return if (span / 100 > 0) span / 100 else span;
    }
    pub fn largeChange(self: Range) f64 {
        return self.page_step orelse @min(self.maximum - self.minimum, self.smallChange() * 10);
    }
    pub fn normalize(self: Range, value: f64) !f64 {
        try self.validate();
        if (!std.math.isFinite(value)) return error.InvalidValue;
        const bounded = std.math.clamp(value, self.minimum, self.maximum);
        if (self.step == 0 or bounded == self.minimum or bounded == self.maximum) return bounded;
        const remainder = @mod(bounded - self.minimum, self.step);
        return std.math.clamp(bounded - remainder + (if (remainder >= self.step / 2) self.step else @as(f64, 0)), self.minimum, self.maximum);
    }
    pub fn apply(self: Range, current: f64, change: ValueChange) !f64 {
        try self.validate();
        if (!std.math.isFinite(current)) return error.InvalidValue;
        const value = std.math.clamp(current, self.minimum, self.maximum);
        return switch (change) {
            .set => |target| self.normalize(target),
            .minimum => self.minimum,
            .maximum => self.maximum,
            .steps, .pages => |count| blk: {
                if (count == 0 or self.minimum == self.maximum) break :blk value;
                const increment = if (change == .steps) self.smallChange() else self.largeChange();
                var magnitude = increment * @as(f64, @floatFromInt(@abs(@as(i64, count))));
                // An endpoint or pair clamp can lie between step points. The
                // first step reaches the next point in the requested direction.
                if (change == .steps and self.step > 0) {
                    const remainder = @mod(value - self.minimum, self.step);
                    const tolerance = @min(self.step / 4, std.math.floatEps(f64) * @max(1, @max(@abs(value), @abs(self.minimum))) * 4);
                    if (remainder > tolerance and self.step - remainder > tolerance) magnitude = self.step * @as(f64, @floatFromInt(@abs(@as(i64, count)) - 1)) + (if (count < 0) remainder else self.step - remainder);
                }
                if (!std.math.isFinite(magnitude)) break :blk if (count > 0) self.maximum else self.minimum;
                if (count > 0) {
                    if (magnitude >= self.maximum - value) break :blk self.maximum;
                    // Quantization of a small page must not reverse direction.
                    break :blk @max(value, try self.normalize(value + magnitude));
                }
                if (magnitude >= value - self.minimum) break :blk self.minimum;
                break :blk @min(value, try self.normalize(value - magnitude));
            },
        };
    }
    pub fn applyLow(self: Range, current: Values, change: ValueChange) !Values {
        try self.validateValue(current.low);
        try self.validateValue(current.high);
        if (current.low > current.high) return error.InvalidValue;
        return .{ .low = @min(current.high, try self.apply(current.low, change)), .high = current.high };
    }
    pub fn applyHigh(self: Range, current: Values, change: ValueChange) !Values {
        try self.validateValue(current.low);
        try self.validateValue(current.high);
        if (current.low > current.high) return error.InvalidValue;
        return .{ .low = current.low, .high = @max(current.low, try self.apply(current.high, change)) };
    }
};
pub const ValueAction = struct { id: u64, change: ValueChange };
pub const StepButtons = struct { decrement: Rect, increment: Rect };
pub const RangeHit = struct { spec: Range, track: Rect, vertical: bool = false, kind: enum { slider, stepper, splitter } = .slider, step_buttons: ?StepButtons = null };
pub const Chord = struct { key: z.KeyCode, modifiers: z.KeyModifiers = .{}, allow_repeat: bool = false };
pub const Options = struct {
    enabled: bool = true,
    focusable: bool = true,
    /// A non-interactive display may still occlude controls behind its bounds.
    pointer_enabled: bool = true,
    radio_group: ?u64 = null,
    selected: bool = false,
    focus_rect: ?Rect = null,
    range: ?RangeHit = null,
    shortcut: ?Chord = null,
};
pub const Hit = struct { id: u64, rect: Rect, options: Options = .{} };

const HitView = struct { hits: []const Hit, mapped: ?*const affine_state.Snapshot };
fn resolve(view: HitView, point: z.Point) ?usize {
    var i = view.hits.len;
    while (i > 0) {
        i -= 1;
        const item = view.hits[i];
        // The exact existing reverse traversal includes disabled occluders.
        const contains = if (view.mapped) |mapped| mapped.hitContains(i, affine.Rect.from(item.rect), affine.Point.from(point)) catch false else item.rect.contains(point);
        if (contains) return i;
    }
    return null;
}
fn pointerEligibleView(view: HitView, item: Hit, index: usize) bool {
    if (!item.options.enabled or !item.options.pointer_enabled or item.rect.width <= 0 or item.rect.height <= 0) return false;
    return if (view.mapped) |mapped| index < mapped.hit_len and mapped.hits[index].visible else true;
}
fn sameHitGeometry(a: *const affine_state.Snapshot, ai: usize, b: *const affine_state.Snapshot, bi: usize) bool {
    if (ai >= a.hit_len or ai >= a.hits.len or bi >= b.hit_len or bi >= b.hits.len) return false;
    return affine_state.sameReferenceGeometry(&a.geometry, a.hits[ai].reference, &b.geometry, b.hits[bi].reference);
}
const RecipientTestProbe = struct {
    fn focusText(_: *anyopaque, _: *text_fields.EventScope) !z.TextClientToken {
        return error.NotBound;
    }
    fn focusControl(_: *anyopaque, _: *text_fields.EventScope) !void {}
    fn blur(_: *anyopaque, _: z.Window) !void {}
    fn textInput(_: *anyopaque, _: *text_fields.EventScope, _: z.Event) !text_fields.Result {
        return .{};
    }
    fn textAction(_: *anyopaque, _: *text_fields.EventScope, _: text_fields.Action) !text_fields.Result {
        return .{};
    }
    fn controlInput(_: *anyopaque, _: *text_fields.EventScope, _: z.Event) !text_fields.ControlResult {
        return .{};
    }
    fn controlAction(_: *anyopaque, _: *text_fields.EventScope, _: text_fields.ControlAction) !text_fields.ControlResult {
        return .{};
    }
    fn text(context: *anyopaque) text_fields.Registration {
        return .{ .context = context, .focus = focusText, .blur = blur, .input = textInput, .action = textAction };
    }
    fn control(context: *anyopaque) text_fields.ControlRegistration {
        return .{ .context = context, .focus = focusControl, .blur = blur, .input = controlInput, .action = controlAction };
    }
};

test "mixed recipient candidate bindings preserve control focus across text-only closure" {
    var context: u8 = 0;
    const fields = try text_fields.Workspace.create(std.testing.allocator, 21, .{ .fields = 2 }, 0);
    defer fields.release();
    var value: Input = .{ .fields = fields };
    const text = try fields.register(1, RecipientTestProbe.text(&context));
    const control = try fields.registerControl(2, RecipientTestProbe.control(&context));
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    try std.testing.expectError(error.NoFrame, value.bindControlRecipient(0, 2, control));
    value.beginFrame();
    try value.add(1, bounds);
    try value.add(2, bounds);
    try std.testing.expectError(error.InvalidBinding, value.bindControlRecipient(0, 2, control));
    try std.testing.expectError(error.InvalidRecipientKind, value.bindTextField(1, 2, control));
    try std.testing.expectError(error.InvalidRecipientKind, value.bindControlRecipient(0, 1, text));
    try value.bindTextField(0, 1, text);
    try value.bindControlRecipient(1, 2, control);
    try value.validateFrame();
    value.commitFrame();
    value.setFocused(2);
    value.active = 2;
    try fields.closeKind(.text);
    value.beginFrame();
    try value.add(2, bounds);
    try value.bindControlRecipient(0, 2, control);
    try value.validateFrame();
    value.commitFrame();
    try std.testing.expectEqual(@as(?u64, 2), value.focused);
    try std.testing.expectEqual(@as(?u64, 2), value.active);
    try std.testing.expectEqualDeep(control, try fields.accepted(0, 2));
}

test "retired recipient same id replacement cannot inherit focus or pointer capture" {
    var context: u8 = 0;
    const fields = try text_fields.Workspace.create(std.testing.allocator, 22, .{ .fields = 1 }, 0);
    defer fields.release();
    var value: Input = .{ .fields = fields };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    const first = try fields.registerControl(7, RecipientTestProbe.control(&context));
    value.beginFrame();
    try value.add(7, bounds);
    try value.bindControlRecipient(0, 7, first);
    value.commitFrame();
    value.setFocused(7);
    value.active = 7;
    value.beginFrame();
    try value.add(7, .{ .x = 50, .y = 0, .width = 20, .height = 20 });
    try value.bindControlRecipient(0, 7, first);
    value.cancelFrame();
    try std.testing.expectEqualDeep(bounds, value.hits[0].rect);
    try std.testing.expectEqual(@as(?u64, 7), value.focused);
    try std.testing.expectEqual(@as(?u64, 7), value.active);
    try std.testing.expect(try fields.unregister(first));
    const second = try fields.registerControl(7, RecipientTestProbe.control(&context));
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(second.serial > first.serial);
    try std.testing.expectError(error.StaleTextField, fields.byId(value.hits[0..value.len], 7));
    value.beginFrame();
    try value.add(7, bounds);
    try value.bindControlRecipient(0, 7, second);
    try value.validateFrame();
    value.commitFrame();
    try std.testing.expect(value.focused == null and value.active == null);
    try std.testing.expectEqualDeep(second, try fields.accepted(0, 7));
}

test "failed replacement candidate retains visual front while revoking retired callbacks" {
    var context: u8 = 0;
    const fields = try text_fields.Workspace.create(std.testing.allocator, 23, .{ .fields = 2 }, 0);
    defer fields.release();
    var value: Input = .{ .fields = fields };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    const first = try fields.register(7, RecipientTestProbe.text(&context));
    value.beginFrame();
    try value.add(7, bounds);
    try value.bindTextField(0, 7, first);
    value.commitFrame();
    value.setFocused(7);
    var entered = try fields.borrow(first);
    defer entered.end();
    try std.testing.expect(!try fields.unregister(first));
    const second = try fields.registerControl(7, RecipientTestProbe.control(&context));
    value.beginFrame();
    try value.add(7, bounds);
    try value.bindControlRecipient(0, 7, second);
    try std.testing.expect(try fields.unregister(second));
    try std.testing.expectError(error.StaleTextField, value.validateFrame());
    value.cancelFrame();
    try std.testing.expectEqualDeep(bounds, value.hits[0].rect);
    try std.testing.expectEqualDeep(first, try fields.publishedKey(0, 7));
    try std.testing.expectEqual(text_fields.Kind.text, try fields.publishedKind(0));
    try std.testing.expectError(error.StaleTextField, entered.registration());
    const third = try fields.registerControl(7, RecipientTestProbe.control(&context));
    try std.testing.expectEqual(text_fields.Kind.control, try fields.kind(third));
    try std.testing.expectEqual(text_fields.Kind.text, try fields.publishedKind(0));
    value.beginFrame();
    try value.add(7, bounds);
    try value.bindControlRecipient(0, 7, third);
    value.commitFrame();
    try std.testing.expect(value.focused == null);
    try std.testing.expectEqual(text_fields.Kind.control, try fields.publishedKind(0));
}

fn clickTestWorkspace() !*pointer_clicks.Workspace {
    const Callbacks = struct {
        fn click(_: *anyopaque, _: z.Window, _: pointer_clicks.Click) pointer_clicks.Outcome {
            unreachable;
        }
    };
    return pointer_clicks.Workspace.create(std.testing.allocator, 0, .{ .app = 1, .index = 2, .generation = 3 }, .{}, .{ .context = @ptrFromInt(4096), .on_click = Callbacks.click }, 0);
}
fn clickTestHistory(workspace: *pointer_clicks.Workspace, target: pointer_clicks.kernel.Target, held: bool) !void {
    const timing: pointer_clicks.kernel.Timing = .{ .tick_ms = 10, .position = .{ .x = 5, .y = 5, .domain = 1 }, .policy = .{ .interval_ms = 500, .min_x = -100, .max_x = 100, .min_y = -100, .max_y = 100 } };
    const down = try workspace.state.beginDown(.{ .sequence = 1, .previous_completed_sequence = 0, .timing = timing, .point = .{ .x = 5, .y = 5 } });
    _ = try workspace.state.claim(down, target);
    workspace.state.finish(down);
    const up = try workspace.state.beginUp(.{ .sequence = 1, .point = .{ .x = 5, .y = 5 } });
    const completion = try workspace.state.takeUp(up, target);
    try std.testing.expect(workspace.state.complete(completion, .{ .accepted = true, .authorized = true, .eligible = true }));
    workspace.state.finish(up);
    if (held) {
        const next = try workspace.state.beginDown(.{ .sequence = 2, .previous_completed_sequence = 1, .timing = timing, .point = .{ .x = 15, .y = 5 } });
        _ = try workspace.state.claim(next, target);
        workspace.state.finish(next);
    }
}

test "pointer front compares full affine clip values rather than recycled ids" {
    const workspace = try clickTestWorkspace();
    defer {
        workspace.close();
        workspace.release();
    }
    var value: Input = .{ .clicks = workspace };
    const target = try workspace.state.mint(7);
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    var snapshots: [3]affine_state.Snapshot = .{ .{}, .{}, .{} };
    for (&snapshots, 0..) |*snapshot, ordinal| {
        if (ordinal == 1) {
            _ = try snapshot.geometry.addSpace(.{ .x0 = 90 });
            _ = try snapshot.geometry.addClip(.identity, null, .{ .x = 90, .y = 90, .width = 1, .height = 1 });
        }
        const space = try snapshot.geometry.addSpace(.{ .xy = 0.5 });
        const parent = try snapshot.geometry.addClip(.identity, null, .{ .x = 0, .y = 0, .width = if (ordinal == 2) 90 else 100, .height = 100 });
        const leaf = try snapshot.geometry.addClip(space, parent, .{ .x = 0, .y = 0, .width = 50, .height = 50 });
        value.beginMappedFrame(snapshot);
        try value.addMapped(7, bounds, .{}, .{ .space = space, .clip = leaf });
        try value.bindClickTarget(0, 7, target);
        try value.validateFrame();
        value.commitFrame();
        if (ordinal == 0) try clickTestHistory(workspace, target, true) else if (ordinal == 1) {
            try std.testing.expect(workspace.state.savedHistoryPoint() != null and workspace.state.savedHeldPoint() != null);
        } else {
            // Both saved points remain inside every clip. Changed full chain
            // values still revoke, even though the recycled IDs look equal.
            try std.testing.expect(workspace.state.savedHistoryPoint() == null and workspace.state.savedHeldPoint() == null);
        }
    }
}

test "pointer repaint checks first-held and history points independently and failures keep front" {
    const workspace = try clickTestWorkspace();
    defer {
        workspace.close();
        workspace.release();
    }
    var value: Input = .{ .clicks = workspace };
    const target = try workspace.state.mint(7);
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    value.beginFrame();
    try value.add(7, bounds);
    try value.bindClickTarget(0, 7, target);
    value.commitFrame();
    try clickTestHistory(workspace, target, true);
    value.beginFrame();
    try value.add(7, bounds);
    try value.bindClickTarget(0, 7, target);
    try value.addWithOptions(8, .{ .x = 12, .y = 0, .width = 5, .height = 20 }, .{ .enabled = false });
    value.commitFrame();
    try std.testing.expect(workspace.state.savedHistoryPoint() != null and workspace.state.savedHeldPoint() == null);
    const front = workspace.state.front_serial;
    value.beginFrame();
    try value.add(7, .{ .x = 100, .y = 0, .width = 20, .height = 20 });
    try value.bindClickTarget(0, 7, target);
    value.cancelFrame();
    try std.testing.expectEqual(front, workspace.state.front_serial);
    try std.testing.expectEqualDeep(bounds, value.hits[0].rect);
    try std.testing.expect(workspace.state.savedHistoryPoint() != null);
    value.beginFrame();
    try value.add(7, bounds);
    try value.bindClickTarget(0, 7, target);
    try value.addWithOptions(9, .{ .x = 90, .y = 0, .width = 5, .height = 20 }, .{ .enabled = false });
    value.commitFrame();
    try std.testing.expect(workspace.state.savedHistoryPoint() != null);
}

test "pointer failed mapped append rolls back the parallel association" {
    const workspace = try clickTestWorkspace();
    defer {
        workspace.close();
        workspace.release();
    }
    var value: Input = .{ .clicks = workspace };
    var snapshot: affine_state.Snapshot = .{};
    value.beginMappedFrame(&snapshot);
    try std.testing.expectError(error.InvalidSpace, value.addMapped(7, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{}, .{ .space = @enumFromInt(999) }));
    try std.testing.expectEqual(@as(usize, 0), value.pending_len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.hit_len);
    try std.testing.expectEqual(@as(usize, 0), workspace.state.banks[workspace.state.front ^ 1].len);
    try value.validateFrame();
    value.cancelFrame();
}

test "pointer controls need not join keyboard navigation and disabled hits still occlude" {
    var input: Input = .{};
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    try input.add(1, bounds);
    try input.addWithOptions(2, bounds, .{ .focusable = false });
    try std.testing.expectEqual(@as(?u64, 2), input.hit(.{ .x = 5, .y = 5 }));
    input.down(.{ .x = 5, .y = 5 });
    try std.testing.expect(input.focused == null);
    try std.testing.expectEqual(@as(?u64, 2), input.up(.{ .x = 5, .y = 5 }));
    input.tab();
    try std.testing.expectEqual(@as(?u64, 1), input.focused);
    try input.addWithOptions(3, bounds, .{ .enabled = false });
    try std.testing.expect(input.hit(.{ .x = 5, .y = 5 }) == null);
    try input.addWithOptions(4, bounds, .{ .focusable = false, .pointer_enabled = false });
    try std.testing.expect(input.hit(.{ .x = 5, .y = 5 }) == null);
    try std.testing.expectEqual(@as(u64, 4), input.hitControl(.{ .x = 5, .y = 5 }).?.id);
}

/// Stable IDs, previous-frame hit regions and bounded storage; no frame allocator.
pub const Input = struct {
    hits: [128]Hit = undefined,
    len: usize = 0,
    pending: [128]Hit = undefined,
    pending_len: usize = 0,
    building: bool = false,
    active: ?u64 = null,
    focused: ?u64 = null,
    drag_last: ?f64 = null,
    pressed_step: ?i32 = null,
    /// Parallel coordinates exist only for an explicitly prepared Context.
    mapped: ?*const affine_state.Snapshot = null,
    pending_mapped: ?*affine_state.Snapshot = null,
    scopes: ?*shortcut_scopes.Workspace = null,
    /// Preserve across detach so a replaced workspace cannot revive old tokens.
    scope_epoch: u64 = 0,
    clicks: ?*pointer_clicks.Workspace = null,
    fields: ?*text_fields.Workspace = null,
    /// Independent installation high-water, including detach/re-attach.
    click_epoch: u64 = 0,
    click_preparing: bool = false,

    /// Change the existing control focus authority. Every actual mutation
    /// revokes an older scoped key, including A->B->A before its task is taken.
    pub fn setFocused(self: *Input, id: ?u64) void {
        if (self.focused == id) return;
        self.focused = id;
        if (self.scopes) |scopes| {
            scopes.request = null;
            _ = scopes.advanceRouting();
        }
    }

    pub fn beginFrame(self: *Input) void {
        self.pending_len = 0;
        self.building = true;
        self.pending_mapped = null;
        if (self.scopes) |scopes| scopes.beginFrame();
        if (self.clicks) |clicks| clicks.beginFrame();
        if (self.fields) |fields| fields.beginFrame() catch |err| {
            fields.frame_failure = err;
        };
    }
    pub fn beginMappedFrame(self: *Input, snapshot: *affine_state.Snapshot) void {
        self.beginFrame();
        std.debug.assert(snapshot.hit_len == 0);
        self.pending_mapped = snapshot;
    }
    pub fn cancelFrame(self: *Input) void {
        if (self.scopes) |scopes| scopes.cancelFrame();
        if (self.clicks) |clicks| clicks.state.cancelFrame();
        if (self.fields) |fields| fields.cancelFrame();
        self.pending_len = 0;
        self.building = false;
        self.pending_mapped = null;
    }
    pub fn commitFrame(self: *Input) void {
        if (self.clicks != null and !self.building) return;
        std.debug.assert(self.frameValid());
        if (self.scopes) |scopes| scopes.commit(self.pending[0..self.pending_len], self.pending_mapped);
        if (self.clicks) |clicks| self.commitClickFrame(clicks);
        if (self.fields) |fields| {
            if (self.focused) |id| {
                if (self.recipientContinuous(fields, id, true)) |continuous| {
                    if (!continuous) {
                        self.setFocused(null);
                        self.cancelPress();
                    }
                }
            }
            if (self.active) |id| if (self.recipientContinuous(fields, id, false)) |continuous| {
                if (!continuous) self.cancelPress();
            };
            fields.commitFrame(self.pending_len);
        }
        @memcpy(self.hits[0..self.pending_len], self.pending[0..self.pending_len]);
        self.len = self.pending_len;
        self.mapped = self.pending_mapped;
        self.pending_mapped = null;
        self.building = false;
        if (self.focused) |id| if (!self.available(id)) {
            self.setFocused(null);
        };
        if (self.active) |id| if (!self.pointerAvailable(id)) {
            self.cancelPress();
        };
    }
    fn recipientContinuous(self: *const Input, fields: *const text_fields.Workspace, id: u64, focused: bool) ?bool {
        var old: ?text_fields.Key = null;
        for (self.hits[0..self.len], 0..) |item, index| if (item.id == id) {
            old = fields.publishedKey(index, id) catch return null;
            break;
        };
        const key = old orelse return null;
        for (self.pending[0..self.pending_len], 0..) |item, index| if (item.id == id) {
            const mark = fields.banks[fields.front ^ 1].marks[index];
            const candidate_eligible = item.options.enabled and (if (focused) item.options.focusable else item.options.pointer_enabled);
            return candidate_eligible and mark.serial == key.serial and mark.slot == key.slot;
        };
        return false;
    }
    pub fn checkpoint(self: *const Input) usize {
        return if (self.building) self.pending_len else self.len;
    }
    pub fn rollback(self: *Input, length: usize) void {
        if (self.building) {
            if (self.clicks) |clicks| clicks.state.rollback(length) catch {
                clicks.frame_failure = error.InvalidCheckpoint;
                return;
            };
            self.pending_len = length;
            if (self.fields) |fields| fields.rollback(length);
            if (self.pending_mapped) |mapped| mapped.hit_len = length;
        } else if (self.clicks == null and self.fields == null) self.len = length;
    }
    pub fn frameValid(self: *const Input) bool {
        self.validateFrame() catch return false;
        return true;
    }
    pub fn validateFrame(self: *const Input) !void {
        if (self.pending_mapped) |mapped| if (mapped.hit_len != self.pending_len) return error.InvalidHit;
        if (self.scopes) |scopes| try scopes.validateCandidate(self.pending[0..self.pending_len], self.pending_mapped);
        if (self.fields) |fields| try fields.validateFrame(self.pending[0..self.pending_len]);
        if (self.clicks) |clicks| {
            if (!self.building) return error.NoFrame;
            if (clicks.frame_failure) |err| return err;
            try clicks.state.validateFrame(self.pending_len);
        }
    }
    fn eligible(self: *const Input, item: Hit, index: usize) bool {
        const bounds = item.options.focus_rect orelse item.rect;
        if (!item.options.enabled or !item.options.focusable or bounds.width <= 0 or bounds.height <= 0) return false;
        return if (self.mapped) |mapped| index < mapped.hit_len and mapped.hits[index].focus_bounds != null else true;
    }
    fn pointerEligible(self: *const Input, item: Hit, index: usize) bool {
        return pointerEligibleView(.{ .hits = self.hits[0..self.len], .mapped = self.mapped }, item, index);
    }
    fn pointerAvailable(self: *const Input, id: u64) bool {
        for (self.hits[0..self.len], 0..) |item, index| if (item.id == id) return self.pointerEligible(item, index);
        return false;
    }
    pub fn available(self: *const Input, id: u64) bool {
        for (self.hits[0..self.len], 0..) |item, index| if (item.id == id) return self.eligible(item, index);
        return false;
    }

    /// The topmost accepted control, including disabled occluders. This does
    /// not authorize activation or keyboard focus.
    pub fn hitControl(self: *const Input, point: z.Point) ?Hit {
        return self.hits[self.hitControlIndex(point) orelse return null];
    }
    pub fn hitControlIndex(self: *const Input, point: z.Point) ?usize {
        return resolve(.{ .hits = self.hits[0..self.len], .mapped = self.mapped }, point);
    }
    pub fn hit(self: *const Input, point: z.Point) ?u64 {
        const item = self.hitControl(point) orelse return null;
        return if (self.pointerAvailable(item.id)) item.id else null;
    }
    pub fn down(self: *Input, point: z.Point) void {
        self.cancelPress();
        self.active = self.hit(point);
        self.setFocused(if (self.active) |id| (if (self.available(id)) id else null) else null);
        if (self.active) |id| {
            const index = self.indexOf(id).?;
            const local = self.localPoint(index, point) orelse return;
            if (self.hits[index].options.range) |range| if (range.step_buttons) |buttons| {
                self.pressed_step = if (affine.Rect.from(buttons.decrement).contains(local)) @as(i32, -1) else if (affine.Rect.from(buttons.increment).contains(local)) @as(i32, 1) else null;
            };
        }
    }
    pub fn cancelPress(self: *Input) void {
        self.active = null;
        self.drag_last = null;
        self.pressed_step = null;
    }
    pub fn up(self: *Input, point: z.Point) ?u64 {
        const id = self.active orelse return null;
        self.cancelPress();
        if (self.get(id)) |item| if (item.options.range != null) return null;
        return if (self.hit(point) == id) id else null;
    }
    pub fn tab(self: *Input) void {
        self.tabDirection(false);
    }
    pub fn tabDirection(self: *Input, backward: bool) void {
        if (self.len == 0) {
            self.setFocused(null);
            return;
        }
        var start: usize = if (backward) 0 else self.len - 1;
        var current_group: ?u64 = null;
        for (self.hits[0..self.len], 0..) |item, i| if (self.focused == item.id) {
            start = i;
            current_group = item.options.radio_group;
            break;
        };
        var step: usize = 1;
        while (step <= self.len) : (step += 1) {
            const index = if (backward) (start + self.len - step) % self.len else (start + step) % self.len;
            const item = self.hits[index];
            if (!self.eligible(item, index)) continue;
            if (item.options.radio_group) |group| {
                if (current_group == group) continue;
                var first: ?u64 = null;
                var selected: ?u64 = null;
                for (self.hits[0..self.len], 0..) |peer, peer_index| if (peer.options.radio_group == group and self.eligible(peer, peer_index)) {
                    first = first orelse peer.id;
                    if (peer.options.selected) selected = selected orelse peer.id;
                };
                if (item.id != (selected orelse first.?)) continue;
            }
            self.setFocused(item.id);
            return;
        }
        if (self.focused) |id| if (self.available(id)) return;
        self.setFocused(null);
    }
    pub fn activation(self: *const Input) ?u64 {
        const id = self.focused orelse return null;
        const index = self.indexOf(id) orelse return null;
        const item = self.hits[index];
        return if (self.eligible(item, index) and item.options.range == null) id else null;
    }
    pub fn add(self: *Input, id: u64, rect: Rect) error{ TooManyControls, DuplicateId, NoFrame }!void {
        self.addWithOptions(id, rect, .{}) catch |err| switch (err) {
            error.MultipleRadioSelection => unreachable,
            error.DuplicateShortcut, error.InvalidShortcut => unreachable,
            error.DuplicateId => return error.DuplicateId,
            error.TooManyControls => return error.TooManyControls,
            error.NoFrame => return error.NoFrame,
        };
    }
    pub fn addWithOptions(self: *Input, id: u64, rect: Rect, options: Options) error{ TooManyControls, DuplicateId, MultipleRadioSelection, DuplicateShortcut, InvalidShortcut, NoFrame }!void {
        if ((self.scopes != null or self.clicks != null or self.fields != null) and !self.building) return error.NoFrame;
        const list = if (self.building) &self.pending else &self.hits;
        const length = if (self.building) &self.pending_len else &self.len;
        if (options.shortcut) |shortcut| if (!options.focusable or shortcut.key == .unknown) return error.InvalidShortcut;
        const member: u8 = if (self.scopes) |scopes| (if (self.building) scopes.current else 0) else 0;
        for (list[0..length.*], 0..) |item, index| {
            if (item.id == id) return error.DuplicateId;
            if (options.radio_group != null and options.selected and item.options.radio_group == options.radio_group and item.options.selected) return error.MultipleRadioSelection;
            const same_scope = if (self.scopes) |scopes| (if (self.building) scopes.pending().members[index] else scopes.accepted().members[index]) == member else true;
            if (same_scope) if (options.shortcut) |shortcut| if (item.options.shortcut) |existing| if (shortcut.key == existing.key and std.meta.eql(shortcut.modifiers, existing.modifiers)) return error.DuplicateShortcut;
        }
        if (length.* == list.len) return error.TooManyControls;
        if (self.clicks) |clicks| {
            const index = clicks.state.append() catch |err| return switch (err) {
                error.CapacityExceeded => error.TooManyControls,
                else => error.NoFrame,
            };
            if (index != length.*) {
                clicks.frame_failure = error.InvalidBinding;
                return error.NoFrame;
            }
        }
        list[length.*] = .{ .id = id, .rect = rect, .options = options };
        if (self.scopes) |scopes| {
            if (self.building) scopes.pending().members[length.*] = member;
        }
        length.* += 1;
    }
    pub fn get(self: *const Input, id: u64) ?Hit {
        for (self.hits[0..self.len]) |item| if (item.id == id) return item;
        return null;
    }
    fn indexOf(self: *const Input, id: u64) ?usize {
        for (self.hits[0..self.len], 0..) |item, index| if (item.id == id) return index;
        return null;
    }
    fn localPoint(self: *const Input, index: usize, point: z.Point) ?affine.Point {
        return if (self.mapped) |mapped| mapped.localHitPoint(index, affine.Point.from(point)) catch null else affine.Point.from(point);
    }
    /// A failed mapped append leaves both the hit and coordinates unpublished.
    pub fn addMapped(self: *Input, id: u64, rect: Rect, options: Options, reference: affine.Ref) !void {
        if (!self.building) return error.NoFrame;
        const mapped = self.pending_mapped orelse return error.TransformsNotPrepared;
        if (mapped.hit_len != self.pending_len) return error.InvalidHit;
        const before = self.pending_len;
        try self.addWithOptions(id, rect, options);
        errdefer self.rollback(before);
        try mapped.addHit(reference, affine.Rect.from(rect), affine.Rect.from(options.focus_rect orelse rect));
    }
    fn recipientWorkspace(self: *Input, index: usize, id: u64) !*text_fields.Workspace {
        if (!self.building) return error.NoFrame;
        if (index >= self.pending_len or self.pending[index].id != id) return error.InvalidBinding;
        return self.fields orelse error.TextFieldsNotPrepared;
    }
    /// Typed associations share the existing pending/front hit transaction.
    pub fn bindTextField(self: *Input, index: usize, id: u64, key: text_fields.Key) !void {
        if (key.id != id) return error.InvalidBinding;
        try (try self.recipientWorkspace(index, id)).bind(index, key);
    }
    pub fn bindControlRecipient(self: *Input, index: usize, id: u64, key: text_fields.Key) !void {
        return self.bindControlRecipientFrame(index, id, key, .{});
    }
    pub fn bindControlRecipientFrame(self: *Input, index: usize, id: u64, key: text_fields.Key, receipt: text_fields.ControlFrame) !void {
        if (key.id != id) return error.InvalidBinding;
        try (try self.recipientWorkspace(index, id)).bindControlFrame(index, key, receipt);
    }
    /// Candidate metadata only. This does not authorize a pointer ingress.
    pub fn bindClickTarget(self: *Input, index: usize, id: u64, target: pointer_clicks.kernel.Target) !void {
        if (!self.building) return error.NoFrame;
        const clicks = self.clicks orelse return error.PointerClicksNotPrepared;
        if (index >= self.pending_len or self.pending[index].id != id) return error.InvalidBinding;
        try clicks.state.bind(index, id, target);
    }
    noinline fn commitClickFrame(self: *Input, clicks: *pointer_clicks.Workspace) void {
        const old: HitView = .{ .hits = self.hits[0..self.len], .mapped = self.mapped };
        const next: HitView = .{ .hits = self.pending[0..self.pending_len], .mapped = self.pending_mapped };
        const history = if (clicks.state.savedHistoryPoint()) |point| self.clickPointUnchanged(clicks, old, next, point) else false;
        const held = if (clicks.state.savedHeldPoint()) |point| self.clickPointUnchanged(clicks, old, next, point) else false;
        // Input's existing active ID selects its actual accepted association;
        // it is not a new route model. A revoked registered press cannot become
        // an ordinary action merely because the next front reuses that ID.
        const active_index = if (self.active) |id| self.indexOf(id) else null;
        const registered_active = if (active_index) |i| (clicks.state.mark(i) catch 1) != 0 else false;
        clicks.state.commitFrame(self.pending_len, .{ .history = history, .held = held }) catch unreachable;
        if (registered_active and !held) self.cancelPress();
    }
    fn clickPointUnchanged(_: *Input, clicks: *const pointer_clicks.Workspace, old: HitView, next: HitView, point: pointer_clicks.kernel.Point) bool {
        const position: z.Point = .{ .x = @floatCast(point.x), .y = @floatCast(point.y) };
        const a = resolve(old, position) orelse return false;
        const b = resolve(next, position) orelse return false;
        const ah = old.hits[a];
        const bh = next.hits[b];
        if (!pointerEligibleView(old, ah, a) or !pointerEligibleView(next, bh, b) or ah.id != bh.id or !std.meta.eql(ah.rect, bh.rect)) return false;
        const target = clicks.state.bound(a, ah.id) orelse return false;
        if (clicks.pendingMark(b) != target.serial) return false;
        if ((old.mapped == null) != (next.mapped == null)) return false;
        if (old.mapped) |am| return sameHitGeometry(am, a, next.mapped.?, b);
        return true;
    }
    pub fn matchShortcut(self: *const Input, key: z.KeyInput) ?u64 {
        if (self.scopes) |scopes| return self.matchScopedShortcut(scopes, key);
        for (self.hits[0..self.len], 0..) |item, index| if (item.options.shortcut) |binding| {
            if (self.eligible(item, index) and binding.key == key.key and std.meta.eql(binding.modifiers, key.modifiers) and (!key.repeat or binding.allow_repeat)) return item.id;
        };
        return null;
    }
    noinline fn matchScopedShortcut(self: *const Input, scopes: *const shortcut_scopes.Workspace, key: z.KeyInput) ?u64 {
        if (scopes.closed or scopes.serial == 0 or scopes.hit_len != self.len) return null;
        const bank = scopes.accepted();
        var focused: ?u8 = if (self.focused) |id| (if (self.indexOf(id)) |i| bank.members[i] else null) else null;
        if (scopes.window) |window| if (window.hasTextClient() catch true) {
            focused = null;
            if (scopes.text_token) |token| if (std.meta.eql(window.textClientToken(), @as(?z.TextClientToken, token))) {
                if (scopes.text_scope) |id| focused = scopes.scope(id);
            };
        };
        const ranks = scopes.ranks(focused);
        var selected: ?usize = null;
        var best: u8 = 255;
        for (self.hits[0..self.len], 0..) |item, index| if (item.options.shortcut) |binding| {
            const member = bank.members[index];
            if (member < bank.len and ranks[member] < best and scopes.enabled(member) and self.eligible(item, index) and binding.key == key.key and std.meta.eql(binding.modifiers, key.modifiers)) {
                selected = index;
                best = ranks[member];
            }
        };
        const index = selected orelse return null;
        const item = self.hits[index];
        return if (!key.repeat or item.options.shortcut.?.allow_repeat) item.id else null;
    }
    pub const PointerPhase = enum { down, move, up };
    pub fn pointerValue(self: *Input, point: z.Point, phase: PointerPhase) ?ValueAction {
        const id = self.active orelse return null;
        const index = self.indexOf(id) orelse return null;
        const item = self.hits[index];
        const range = item.options.range orelse return null;
        defer if (phase == .up) self.cancelPress();
        if (!self.pointerEligible(item, index)) return null;
        const local = self.localPoint(index, point) orelse return null;
        if (range.kind == .stepper) {
            if (phase != .up or self.hit(point) != id) return null;
            const direction = self.pressed_step orelse return null;
            const buttons = range.step_buttons orelse return null;
            if (!affine.Rect.from(if (direction < 0) buttons.decrement else buttons.increment).contains(local)) return null;
            return .{ .id = id, .change = .{ .steps = direction } };
        }
        const extent = if (range.vertical) range.track.height else range.track.width;
        if (extent <= 0) return null;
        // A vertical slider grows upward; a vertical splitter grows downward with its first pane.
        const along = if (range.vertical) (local.y - range.track.y) / extent else (local.x - range.track.x) / extent;
        const coordinate = if (range.vertical and range.kind != .splitter) 1 - along else along;
        if (!std.math.isFinite(coordinate)) return null;
        const value = range.spec.normalize(range.spec.minimum + std.math.clamp(coordinate, 0, 1) * (range.spec.maximum - range.spec.minimum)) catch return null;
        if (self.drag_last == value) return null;
        self.drag_last = value;
        return .{ .id = id, .change = .{ .set = value } };
    }
    pub fn rangeKey(self: *const Input, key: z.KeyInput) ?ValueAction {
        if (key.modifiers.control or key.modifiers.alt or key.modifiers.super) return null;
        const id = self.focused orelse return null;
        const index = self.indexOf(id) orelse return null;
        const item = self.hits[index];
        if (!self.eligible(item, index) or item.options.range == null) return null;
        const range = item.options.range.?;
        const downward = range.kind == .splitter and range.vertical;
        const change: ValueChange = switch (key.key) {
            .left => .{ .steps = -1 },
            .right => .{ .steps = 1 },
            .down => .{ .steps = if (downward) 1 else -1 },
            .up => .{ .steps = if (downward) -1 else 1 },
            .page_down => .{ .pages = -1 },
            .page_up => .{ .pages = 1 },
            .home => .minimum,
            .end => .maximum,
            else => return null,
        };
        return .{ .id = id, .change = change };
    }
    pub fn spatial(self: *Input, key: z.KeyCode) bool {
        const id = self.focused orelse return false;
        const current_index = self.indexOf(id) orelse return false;
        const current = self.hits[current_index];
        const bounds = self.focusBounds(current_index, current) orelse return false;
        const x = @as(f64, bounds.x) + bounds.width / 2;
        const y = @as(f64, bounds.y) + bounds.height / 2;
        var best: ?u64 = null;
        var score = std.math.inf(f64);
        for (self.hits[0..self.len], 0..) |item, index| {
            if (item.id == id or !self.eligible(item, index)) continue;
            const target = self.focusBounds(index, item) orelse continue;
            const dx = @as(f64, target.x) + target.width / 2 - x;
            const dy = @as(f64, target.y) + target.height / 2 - y;
            const primary = switch (key) {
                .left => -dx,
                .right => dx,
                .up => -dy,
                .down => dy,
                else => return false,
            };
            const cross = if (key == .left or key == .right) dy else dx;
            if (primary <= 0) continue;
            const distance = primary * primary + 4 * cross * cross;
            if (distance < score) {
                score = distance;
                best = item.id;
            }
        }
        self.setFocused(best orelse return false);
        return true;
    }
    fn focusBounds(self: *const Input, index: usize, item: Hit) ?affine.Rect {
        if (self.mapped) |mapped| return if (index < mapped.hit_len) mapped.hits[index].focus_bounds else null;
        return affine.Rect.from(item.options.focus_rect orelse item.rect);
    }
    /// Radio groups use arrows/Home/End to select one enabled visible peer.
    pub fn navigate(self: *Input, key: z.EditKey) ?u64 {
        if (key.control or key.shift) return null;
        const focused = self.focused orelse return null;
        var index: usize = 0;
        while (index < self.len and self.hits[index].id != focused) : (index += 1) {}
        if (index == self.len or !self.eligible(self.hits[index], index)) return null;
        const group = self.hits[index].options.radio_group orelse return null;
        const backwards = switch (key.key) {
            .left, .up, .end => true,
            .right, .down, .home => false,
            else => return null,
        };
        const from = switch (key.key) {
            .home => self.len - 1,
            .end => 0,
            else => index,
        };
        var step: usize = 1;
        while (step <= self.len) : (step += 1) {
            const i = if (backwards) (from + self.len - step) % self.len else (from + step) % self.len;
            const item = self.hits[i];
            if (item.options.radio_group == group and self.eligible(item, i)) {
                self.setFocused(item.id);
                return item.id;
            }
        }
        return null;
    }
};

test "button requires press and release on same stable control" {
    var input: Input = .{};
    try input.add(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
    try std.testing.expect(input.up(.{ .x = 10, .y = 10 }) == null);
    input.down(.{ .x = 10, .y = 10 });
    try std.testing.expect(input.up(.{ .x = 20, .y = 10 }) == null);
    input.down(.{ .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(?u64, 1), input.up(.{ .x = 10, .y = 10 }));
    try std.testing.expectError(error.DuplicateId, input.add(1, input.hits[0].rect));
}

test "removed focused control cannot activate" {
    var input: Input = .{};
    try input.add(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
    input.tab();
    try std.testing.expectEqual(@as(?u64, 1), input.activation());
    input.len = 0;
    try std.testing.expect(input.activation() == null);
}

test "disabled occludes, clipping skips focus, groups navigate, failed frames preserve snapshot" {
    var state: Input = .{};
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    try state.add(1, bounds);
    try state.addWithOptions(2, bounds, .{ .enabled = false });
    try std.testing.expect(state.hit(.{ .x = 1, .y = 1 }) == null);
    try state.addWithOptions(3, .{ .x = 0, .y = 0, .width = 0, .height = 20 }, .{});
    try state.addWithOptions(4, bounds, .{ .radio_group = 9 });
    try state.addWithOptions(5, bounds, .{ .radio_group = 9, .selected = true });
    state.tab();
    try std.testing.expectEqual(@as(?u64, 1), state.focused);
    state.tab();
    try std.testing.expectEqual(@as(?u64, 5), state.focused);
    try std.testing.expectEqual(@as(?u64, 4), state.navigate(.{ .key = .left }));
    state.tab();
    try std.testing.expectEqual(@as(?u64, 1), state.focused);
    state.beginFrame();
    try state.add(6, bounds);
    try std.testing.expect(state.available(1) and !state.available(6));
    state.cancelFrame();
    try std.testing.expect(state.available(1));
    state.down(.{ .x = 1, .y = 1 });
    state.beginFrame();
    try state.add(6, bounds);
    state.commitFrame();
    try std.testing.expect(state.focused == null and state.active == null);
    try std.testing.expect(state.up(.{ .x = 1, .y = 1 }) == null);
}

test "range changes apply to current application values and preserve endpoints" {
    const spec: Range = .{ .minimum = -2, .maximum = 9, .step = 2, .page_step = 6 };
    var value: f64 = -2;
    for (0..3) |_| value = try spec.apply(value, .{ .steps = 1 });
    try std.testing.expectEqual(@as(f64, 4), value);
    try std.testing.expectEqual(@as(f64, 9), try spec.apply(value, .{ .pages = 1 }));
    try std.testing.expectEqual(@as(f64, 8), try spec.apply(9, .{ .steps = -1 }));
    try std.testing.expectEqual(@as(f64, -2), try spec.apply(9, .{ .steps = std.math.minInt(i32) }));
    const decimal: Range = .{ .minimum = 0.1, .maximum = 1.1, .step = 0.2 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), try decimal.apply(0.1, .{ .steps = 1 }), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), try decimal.apply(0.3, .{ .steps = -1 }), 0.000001);
    const pair: Values = .{ .low = 2, .high = 6 };
    try std.testing.expectEqual(Values{ .low = 6, .high = 6 }, try spec.applyLow(pair, .maximum));
    try std.testing.expectEqual(Values{ .low = 2, .high = 2 }, try spec.applyHigh(pair, .minimum));
    try std.testing.expectError(error.InvalidValue, spec.apply(0, .{ .set = std.math.nan(f64) }));
    try std.testing.expectError(error.InvalidRange, (Range{ .minimum = 2, .maximum = 1 }).validate());
}

test "relative range actions preserve direction and zero preserves off-grid values" {
    const spec: Range = .{ .minimum = 0, .maximum = 10, .step = 1, .page_step = 0.1 };
    try std.testing.expectEqual(@as(f64, 2), try spec.apply(1.4, .{ .steps = 1 }));
    try std.testing.expectEqual(@as(f64, 2), try spec.apply(1.6, .{ .steps = 1 }));
    try std.testing.expectEqual(@as(f64, 1), try spec.apply(1.4, .{ .steps = -1 }));
    try std.testing.expectEqual(@as(f64, 1), try spec.apply(1.6, .{ .steps = -1 }));
    try std.testing.expectEqual(@as(f64, 4), try spec.apply(1.4, .{ .steps = 3 }));
    try std.testing.expectEqual(@as(f64, 0), try spec.apply(1.6, .{ .steps = -3 }));
    for ([_]f64{ 0, 0.4, 1.4, 1.6, 9.6, 10 }) |current| {
        for ([_]i32{ -3, -1, 0, 1, 3 }) |count| {
            for ([_]ValueChange{ .{ .steps = count }, .{ .pages = count } }) |change| {
                const updated = try spec.apply(current, change);
                try std.testing.expect(updated >= spec.minimum and updated <= spec.maximum);
                if (count > 0) try std.testing.expect(updated >= current);
                if (count < 0) try std.testing.expect(updated <= current);
                if (count == 0) try std.testing.expectEqual(current, updated);
            }
        }
    }
    const tiny: Range = .{ .minimum = 0, .maximum = 10, .step = 1, .page_step = 0.01 };
    try std.testing.expectEqual(@as(f64, 1.4), try tiny.apply(1.4, .{ .pages = 1 }));
    try std.testing.expectEqual(@as(f64, 1.6), try tiny.apply(1.6, .{ .pages = -1 }));
    const pair: Values = .{ .low = 1.4, .high = 1.6 };
    try std.testing.expectEqual(pair, try spec.applyLow(pair, .{ .pages = 0 }));
    try std.testing.expectEqual(pair, try spec.applyHigh(pair, .{ .steps = 0 }));
    const low_at_limit = try spec.applyLow(pair, .{ .steps = 1 });
    try std.testing.expectEqual(Values{ .low = 1.6, .high = 1.6 }, low_at_limit);
    try std.testing.expectEqual(low_at_limit, try tiny.applyLow(low_at_limit, .{ .pages = 1 }));
    const high_at_limit = try spec.applyHigh(pair, .{ .steps = -1 });
    try std.testing.expectEqual(Values{ .low = 1.4, .high = 1.4 }, high_at_limit);
    try std.testing.expectEqual(high_at_limit, try tiny.applyHigh(high_at_limit, .{ .pages = -1 }));
}

test "range pointer capture clamps outside and stepper requires same explicit button" {
    var state: Input = .{};
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 20 };
    const spec: Range = .{ .minimum = 0, .maximum = 10, .step = 1 };
    try state.addWithOptions(1, bounds, .{ .range = .{ .spec = spec, .track = bounds } });
    state.down(.{ .x = 20, .y = 10 });
    try std.testing.expectEqual(@as(f64, 2), state.pointerValue(.{ .x = 20, .y = 10 }, .down).?.change.set);
    try std.testing.expectEqual(@as(f64, 10), state.pointerValue(.{ .x = 200, .y = -20 }, .move).?.change.set);
    try std.testing.expect(state.pointerValue(.{ .x = 200, .y = -20 }, .up) == null);
    try std.testing.expect(state.active == null and state.up(.{ .x = 20, .y = 10 }) == null);
    state.len = 0;
    try state.addWithOptions(2, bounds, .{ .range = .{ .spec = spec, .track = bounds, .kind = .stepper, .step_buttons = .{ .decrement = .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .increment = .{ .x = 80, .y = 0, .width = 20, .height = 20 } } } });
    state.down(.{ .x = 10, .y = 10 });
    try std.testing.expect(state.pointerValue(.{ .x = 90, .y = 10 }, .up) == null);
    state.down(.{ .x = 50, .y = 10 });
    try std.testing.expect(state.pointerValue(.{ .x = 90, .y = 10 }, .up) == null);
    state.down(.{ .x = 90, .y = 10 });
    try std.testing.expectEqual(@as(i32, 1), state.pointerValue(.{ .x = 90, .y = 10 }, .up).?.change.steps);
    state.down(.{ .x = 90, .y = 10 });
    state.beginFrame();
    try state.addWithOptions(2, bounds, .{ .enabled = false });
    state.commitFrame();
    try std.testing.expect(state.active == null and state.pressed_step == null);
}

test "vertical splitters grow downward for pointer and arrow keys" {
    var state: Input = .{};
    const strip: Rect = .{ .x = 0, .y = 48, .width = 100, .height = 4 };
    const spec: Range = .{ .minimum = 0, .maximum = 1, .step = 0.25 };
    try state.addWithOptions(1, strip, .{ .range = .{ .spec = spec, .track = .{ .x = 50, .y = 0, .width = 0, .height = 100 }, .vertical = true, .kind = .splitter } });
    state.down(.{ .x = 50, .y = 50 });
    try std.testing.expectEqual(@as(f64, 0.5), state.pointerValue(.{ .x = 50, .y = 50 }, .down).?.change.set);
    try std.testing.expectEqual(@as(f64, 0.75), state.pointerValue(.{ .x = 50, .y = 74 }, .move).?.change.set);
    _ = state.pointerValue(.{ .x = 50, .y = 74 }, .up);
    state.setFocused(1);
    try std.testing.expectEqual(@as(i32, 1), state.rangeKey(.{ .key = .down }).?.change.steps);
    try std.testing.expectEqual(@as(i32, -1), state.rangeKey(.{ .key = .up }).?.change.steps);
}

test "reverse tab and shortcuts use committed enabled identities" {
    var state: Input = .{};
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    try state.addWithOptions(1, bounds, .{ .shortcut = .{ .key = .s, .modifiers = .{ .control = true } } });
    try state.addWithOptions(2, bounds, .{ .radio_group = 9 });
    try state.addWithOptions(3, bounds, .{ .radio_group = 9, .selected = true });
    try state.addWithOptions(4, bounds, .{ .enabled = false });
    state.tabDirection(true);
    try std.testing.expectEqual(@as(?u64, 3), state.focused);
    state.tabDirection(true);
    try std.testing.expectEqual(@as(?u64, 1), state.focused);
    state.tabDirection(true);
    try std.testing.expectEqual(@as(?u64, 3), state.focused);
    try std.testing.expectEqual(@as(?u64, 1), state.matchShortcut(.{ .key = .s, .modifiers = .{ .control = true } }));
    try std.testing.expect(state.matchShortcut(.{ .key = .s, .modifiers = .{ .control = true }, .repeat = true }) == null);
    try std.testing.expectError(error.DuplicateShortcut, state.addWithOptions(5, bounds, .{ .shortcut = .{ .key = .s, .modifiers = .{ .control = true } } }));
    state.beginFrame();
    try state.addWithOptions(1, bounds, .{ .enabled = false, .shortcut = .{ .key = .s, .modifiers = .{ .control = true } } });
    state.commitFrame();
    try std.testing.expect(state.matchShortcut(.{ .key = .s, .modifiers = .{ .control = true } }) == null);
}

test "affine hits use exact committed geometry and failed frames keep that snapshot" {
    var state: affine_state.State = .{};
    var input: Input = .{};
    try state.beginFrame(1);
    const pending = try state.pending();
    const rotated = try pending.geometry.addSpace(try (try affine.Affine.rotation(std.math.pi / 4.0)).then(.{ .x0 = 50 }));
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    input.beginMappedFrame(pending);
    try input.addMapped(1, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .{}, .{});
    try input.addMapped(2, bounds, .{}, .{ .space = rotated });
    _ = try state.commitFrame();
    input.commitFrame();
    try std.testing.expectEqual(@as(?u64, 2), input.hit(.{ .x = 50, .y = 14 }));
    try std.testing.expectEqual(@as(?u64, 1), input.hit(.{ .x = 64, .y = 1 }));
    input.down(.{ .x = 50, .y = 14 });
    try state.beginFrame(2);
    input.beginMappedFrame(try state.pending());
    try input.addMapped(3, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .{}, .{});
    input.cancelFrame();
    state.cancelFrame();
    try std.testing.expectEqual(@as(?u64, 2), input.up(.{ .x = 50, .y = 14 }));
    try state.beginFrame(2);
    const replacement = try state.pending();
    const new_rotated = try replacement.geometry.addSpace(try (try affine.Affine.rotation(std.math.pi / 4.0)).then(.{ .x0 = 50 }));
    input.beginMappedFrame(replacement);
    try input.addMapped(1, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .{}, .{});
    try input.addMapped(2, bounds, .{}, .{ .space = new_rotated });
    try input.addMapped(3, bounds, .{ .enabled = false }, .{ .space = new_rotated });
    _ = try state.commitFrame();
    input.commitFrame();
    try std.testing.expect(input.hit(.{ .x = 50, .y = 14 }) == null);
    try std.testing.expectEqual(@as(?u64, 1), input.hit(.{ .x = 64, .y = 1 }));
    input.focused = 2;
    input.tab();
    try std.testing.expectEqual(@as(?u64, 1), input.focused);
}

test "shortcut barriers use the same exact affine clip visibility as accepted hits" {
    for ([_]bool{ false, true }) |inside| {
        var state: affine_state.State = .{};
        const scopes = try shortcut_scopes.Workspace.create(std.testing.allocator, .{});
        defer scopes.release();
        var input: Input = .{ .scopes = scopes };
        try state.beginFrame(1);
        const pending = try state.pending();
        const rotated = try pending.geometry.addSpace(try (try affine.Affine.rotation(std.math.pi / 4.0)).then(.{ .x0 = 50 }));
        const clip = try pending.geometry.addClip(rotated, null, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
        input.beginMappedFrame(pending);
        try input.addMapped(1, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } }, .{});
        try scopes.beginScope(10, .{ .kind = .overlay, .overlay_order = 1 });
        try input.addMapped(2, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .shortcut = .{ .key = .f3 } }, .{});
        try scopes.endScope();
        try scopes.beginScope(20, .{ .kind = .overlay, .overlay_order = 2, .keyboard_barrier = true });
        // Both anchors are in the rotated clip's AABB; only the first lies in
        // the clip polygon. Disabled noninteractive geometry can form a barrier.
        try input.addMapped(3, .{ .x = if (inside) 50 else 64, .y = if (inside) 14 else 1, .width = 1, .height = 1 }, .{ .enabled = false, .focusable = false }, .{ .clip = clip });
        try scopes.endScope();
        _ = try state.commitFrame();
        input.commitFrame();
        try std.testing.expectEqual(@as(?u64, if (inside) null else 2), input.matchShortcut(.{ .key = .f3 }));
    }
}

test "affine range capture and reflected step buttons use local coordinates" {
    var state: affine_state.State = .{};
    var input: Input = .{};
    try state.beginFrame(1);
    const pending = try state.pending();
    const rotated = try pending.geometry.addSpace(.{ .xx = 0, .xy = -2, .yx = 2, .yy = 0, .x0 = 100, .y0 = 10 });
    const reflected = try pending.geometry.addSpace(.{ .xx = -1, .x0 = 100, .y0 = 250 });
    const spec: Range = .{ .minimum = 0, .maximum = 100, .step = 1 };
    input.beginMappedFrame(pending);
    try input.addMapped(1, .{ .x = 0, .y = 0, .width = 100, .height = 20 }, .{ .range = .{ .spec = spec, .track = .{ .x = 10, .y = 10, .width = 80, .height = 0 } } }, .{ .space = rotated });
    try input.addMapped(2, .{ .x = 0, .y = 0, .width = 100, .height = 20 }, .{ .range = .{ .spec = spec, .track = .{ .x = 0, .y = 0, .width = 100, .height = 20 }, .kind = .stepper, .step_buttons = .{ .decrement = .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .increment = .{ .x = 80, .y = 0, .width = 20, .height = 20 } } } }, .{ .space = reflected });
    _ = try state.commitFrame();
    input.commitFrame();
    input.down(.{ .x = 80, .y = 30 });
    try std.testing.expectEqual(@as(f64, 0), input.pointerValue(.{ .x = 80, .y = 30 }, .down).?.change.set);
    try std.testing.expectEqual(@as(f64, 50), input.pointerValue(.{ .x = 80, .y = 110 }, .move).?.change.set);
    try std.testing.expectEqual(@as(f64, 100), input.pointerValue(.{ .x = 80, .y = 500 }, .up).?.change.set);
    try std.testing.expect(input.active == null);
    input.down(.{ .x = 90, .y = 260 });
    try std.testing.expect(input.pointerValue(.{ .x = 10, .y = 260 }, .up) == null);
    input.down(.{ .x = 90, .y = 260 });
    try std.testing.expectEqual(@as(i32, -1), input.pointerValue(.{ .x = 90, .y = 260 }, .up).?.change.steps);
    input.down(.{ .x = 50, .y = 260 });
    try std.testing.expect(input.pointerValue(.{ .x = 50, .y = 260 }, .up) == null);
}

test "affine focus uses window geometry and invalid appends roll back both records" {
    var state: affine_state.State = .{};
    var input: Input = .{};
    try state.beginFrame(1);
    const pending = try state.pending();
    const right = try pending.geometry.addSpace(.{ .x0 = 100 });
    const left = try pending.geometry.addSpace(.{ .x0 = 20 });
    input.beginMappedFrame(pending);
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 20, .height = 20 };
    try std.testing.expectError(error.InvalidSpace, input.addMapped(3, bounds, .{}, .{ .space = @enumFromInt(999) }));
    try std.testing.expectEqual(@as(usize, 0), input.pending_len);
    try std.testing.expectEqual(@as(usize, 0), pending.hit_len);
    try input.addMapped(1, bounds, .{}, .{ .space = right });
    try input.addMapped(2, bounds, .{}, .{ .space = left });
    _ = try state.commitFrame();
    input.commitFrame();
    input.focused = 2;
    try std.testing.expect(input.spatial(.right));
    try std.testing.expectEqual(@as(?u64, 1), input.focused);
    input.down(.{ .x = 110, .y = 10 });
    try state.beginFrame(2);
    input.beginMappedFrame(try state.pending());
    _ = try state.commitFrame();
    input.commitFrame();
    try std.testing.expect(input.active == null and input.focused == null);
}
