const std = @import("std");
const z = @import("ziggurat");

pub const max_fields = 32;
pub const max_hits = 128;
pub const Options = struct { fields: usize = 8, bytes: usize = 32 * 1024 };
pub const Result = struct { handled: bool = false, text_committed: bool = false, input_error: ?anyerror = null, presentation_error: ?anyerror = null };
/// Business model structure and scroll recorded by the accepted visual frame.
/// Selection changes do not advance this structure revision.
pub const ControlFrame = struct {
    model: u64 = 0,
    scroll: f64 = 0,
    pub fn validate(self: ControlFrame) !void {
        if (!std.math.isFinite(self.scroll) or self.scroll < 0) return error.InvalidControlFrame;
    }
};

/// Borrowed only through the entered callback. Context constructs this scope
/// from its accepted recipient before application preprocessing; there is no
/// public constructor from native pointer facts.
pub const EventScope = opaque {
    pub fn window(self: *EventScope) z.Window {
        return state(self).window;
    }
    pub fn validate(self: *EventScope) !void {
        const value = state(self);
        try value.check(value.context);
    }
    pub fn isPointerDown(self: *EventScope) bool {
        return state(self).pointer_down;
    }
    pub fn controlFrame(self: *EventScope) !ControlFrame {
        try self.validate();
        return state(self).control_frame orelse error.UnpublishedControlFrame;
    }
    pub fn controlPublication(self: *EventScope) !u64 {
        _ = try self.controlFrame();
        const publication = state(self).publication;
        if (publication == 0) return error.UnpublishedControlFrame;
        return publication;
    }
    fn state(self: *EventScope) *ScopeState {
        return @ptrCast(@alignCast(self));
    }
};
/// Private module seam used only by Context's entered-event helper.
pub const ScopeState = struct {
    window: z.Window,
    context: *anyopaque,
    check: *const fn (*anyopaque) anyerror!void,
    pointer_down: bool = false,
    control_frame: ?ControlFrame = null,
    publication: u64 = 0,
    pub fn scope(self: *ScopeState) *EventScope {
        return @ptrCast(self);
    }
};
pub const Registration = struct {
    context: *anyopaque,
    focus: *const fn (*anyopaque, *EventScope) anyerror!z.TextClientToken,
    blur: *const fn (*anyopaque, z.Window) anyerror!void,
    input: *const fn (*anyopaque, *EventScope, z.Event) anyerror!Result,
    action: *const fn (*anyopaque, *EventScope, Action) anyerror!Result,
};
pub const Kind = enum { text, control };
pub const ControlResult = struct { handled: bool = false, changed: bool = false, input_error: ?anyerror = null, presentation_error: ?anyerror = null };
pub const ControlAction = union(enum) {
    focus,
    focus_row: struct { row: u64, incarnation: u64 },
    select: struct { row: u64, incarnation: u64 },
    add_selection: struct { row: u64, incarnation: u64 },
    remove_selection: struct { row: u64, incarnation: u64 },
    reveal: struct { row: u64, incarnation: u64 },
    native_row: *const @import("collection_authority.zig").RowRequest,
};
pub const ControlRegistration = struct {
    context: *anyopaque,
    focus: *const fn (*anyopaque, *EventScope) anyerror!void,
    blur: *const fn (*anyopaque, z.Window) anyerror!void,
    input: *const fn (*anyopaque, *EventScope, z.Event) anyerror!ControlResult,
    action: *const fn (*anyopaque, *EventScope, ControlAction) anyerror!ControlResult,
};
const Recipient = union(Kind) { text: Registration, control: ControlRegistration };
pub const Action = union(enum) { set_value: []const u8, select_text: struct { start_utf16: usize, end_utf16: usize }, undo, redo };
pub const Key = struct { epoch: u64, serial: u64, id: u64, slot: u8 };
const Mark = struct { serial: u64 = 0, slot: u8 = 0, kind: Kind = .text };
const Bank = struct { marks: [max_hits]Mark = @splat(.{}), len: usize = 0 };
const Slot = struct {
    serial: u64 = 0,
    id: u64 = 0,
    pins: usize = 0,
    registration: ?Recipient = null,
    token: ?z.TextClientToken = null,
    control_frames: [2]ControlFrame = .{ .{}, .{} },
};

/// Two marker banks join Input's existing front/pending transaction. They
/// contain no hit rectangles, focused ID or business text. Old banks never
/// borrow a callback context: only a current live stable slot can yield one.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    refs: usize = 1,
    epoch: u64,
    serial: u64 = 0,
    publication: u64 = 0,
    front: u1 = 0,
    banks: [2]Bank = .{ .{}, .{} },
    building: bool = false,
    closed: bool = false,
    closed_kinds: [2]bool = .{ false, false },
    frame_failure: ?anyerror = null,

    pub fn create(allocator: std.mem.Allocator, epoch: u64, options: Options, existing_hits: usize) !*Workspace {
        if (epoch == 0) return error.InvalidTextFieldLimits;
        const total = try requiredBytes(options, existing_hits);
        if (total > options.bytes) return error.TextFieldBudgetExceeded;
        const self = try allocator.create(Workspace);
        errdefer allocator.destroy(self);
        const slots = try allocator.alloc(Slot, options.fields);
        @memset(slots, .{});
        self.* = .{ .allocator = allocator, .slots = slots, .epoch = epoch };
        self.banks[0].len = existing_hits;
        return self;
    }
    /// Exact Zig registry allocation, excluding independently owned native
    /// authority metadata and CoordinateOptions geometry. Context checks the
    /// aggregate recipient budget before either owner can be allocated.
    pub fn requiredBytes(options: Options, existing_hits: usize) !usize {
        if (options.fields == 0 or options.fields > max_fields or existing_hits > max_hits) return error.InvalidTextFieldLimits;
        return std.math.add(usize, @sizeOf(Workspace), try std.math.mul(usize, options.fields, @sizeOf(Slot)));
    }
    pub fn bytes(self: *const Workspace) usize {
        return @sizeOf(Workspace) + self.slots.len * @sizeOf(Slot);
    }
    pub fn retain(self: *Workspace) !void {
        self.refs = std.math.add(usize, self.refs, 1) catch return error.CapacityExceeded;
    }
    pub fn release(self: *Workspace) void {
        std.debug.assert(self.refs != 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        const allocator = self.allocator;
        const slots = self.slots;
        allocator.free(slots);
        allocator.destroy(self);
    }
    pub fn close(self: *Workspace) void {
        self.closed = true;
        self.closed_kinds = .{ true, true };
        self.building = false;
        // Withdrawal precedes any future release/allocator callback.
        for (self.slots) |*slot| {
            slot.registration = null;
            slot.token = null;
        }
    }
    pub fn closeKind(self: *Workspace, target: Kind) !void {
        if (self.building) return error.Busy;
        self.closed_kinds[@intFromEnum(target)] = true;
        for (self.slots) |*slot| if (slot.registration) |registration| {
            if (std.meta.activeTag(registration) == target) {
                slot.registration = null;
                slot.token = null;
            }
        };
    }
    pub fn reopenKind(self: *Workspace, target: Kind) !void {
        if (self.building) return error.Busy;
        self.closed = false;
        self.closed_kinds[@intFromEnum(target)] = false;
    }
    pub fn register(self: *Workspace, id: u64, registration: Registration) !Key {
        return self.registerRecipient(id, .{ .text = registration });
    }
    pub fn registerControl(self: *Workspace, id: u64, registration: ControlRegistration) !Key {
        return self.registerRecipient(id, .{ .control = registration });
    }
    fn registerRecipient(self: *Workspace, id: u64, registration: Recipient) !Key {
        if (self.closed or self.closed_kinds[@intFromEnum(std.meta.activeTag(registration))]) return error.TextFieldsClosed;
        if (id == 0) return error.InvalidControlId;
        if (self.serial == std.math.maxInt(u64)) return error.IdExhausted;
        var available: ?usize = null;
        for (self.slots, 0..) |slot, i| {
            if (slot.registration != null and slot.id == id) return error.DuplicateId;
            if (available == null and slot.registration == null and slot.pins == 0) available = i;
        }
        const index = available orelse return error.TextFieldsFull;
        self.serial += 1;
        self.slots[index] = .{ .id = id, .serial = self.serial, .registration = registration };
        return .{ .epoch = self.epoch, .serial = self.serial, .id = id, .slot = @intCast(index) };
    }
    fn lookupSlot(self: *Workspace, key: Key) !*Slot {
        if (key.epoch != self.epoch or key.serial == 0 or key.slot >= self.slots.len) return error.StaleTextField;
        const value = &self.slots[key.slot];
        if (value.serial != key.serial or value.id != key.id) return error.StaleTextField;
        return value;
    }
    pub fn current(self: *Workspace, key: Key) bool {
        if (self.closed) return false;
        const value = self.lookupSlot(key) catch return false;
        const registration = value.registration orelse return false;
        return !self.closed_kinds[@intFromEnum(std.meta.activeTag(registration))];
    }
    pub fn kind(self: *Workspace, key: Key) !Kind {
        if (!self.current(key)) return error.StaleTextField;
        return std.meta.activeTag((try self.lookupSlot(key)).registration.?);
    }
    pub fn requireKind(self: *Workspace, key: Key, expected: Kind) !void {
        if (try self.kind(key) != expected) return error.InvalidRecipientKind;
    }
    /// Returns false while an entered callback still pins the old context.
    /// The owner can retry close after that callback; no queue owns its bytes.
    pub fn unregister(self: *Workspace, key: Key) !bool {
        const value = try self.lookupSlot(key);
        value.registration = null;
        value.token = null;
        return value.pins == 0;
    }
    pub fn setToken(self: *Workspace, key: Key, client: ?z.TextClientToken) !void {
        try self.requireKind(key, .text);
        const value = try self.lookupSlot(key);
        if (self.closed or value.registration == null) return error.StaleTextField;
        value.token = client;
    }
    pub fn token(self: *Workspace, key: Key) !?z.TextClientToken {
        try self.requireKind(key, .text);
        const value = try self.lookupSlot(key);
        if (self.closed or value.registration == null) return error.StaleTextField;
        return value.token;
    }
    pub fn borrow(self: *Workspace, key: Key) !Borrow {
        const value = try self.lookupSlot(key);
        if (!self.current(key)) return error.StaleTextField;
        const pins = std.math.add(usize, value.pins, 1) catch return error.CapacityExceeded;
        try self.retain();
        value.pins = pins;
        return .{ .workspace = self, .key = key };
    }
    pub fn beginFrame(self: *Workspace) !void {
        if (self.building) return error.Busy;
        if (self.publication == std.math.maxInt(u64)) return error.IdExhausted;
        self.banks[self.front ^ 1] = .{};
        self.building = true;
        self.frame_failure = null;
    }
    pub fn bind(self: *Workspace, index: usize, key: Key) !void {
        try self.requireKind(key, .text);
        try self.bindRecipient(index, key);
    }
    pub fn bindControl(self: *Workspace, index: usize, key: Key) !void {
        return self.bindControlFrame(index, key, .{});
    }
    pub fn bindControlFrame(self: *Workspace, index: usize, key: Key, frame: ControlFrame) !void {
        try frame.validate();
        try self.requireKind(key, .control);
        try self.bindRecipient(index, key);
        // No failure is possible after the mark is written. Receipt banks use
        // exactly the marker bank index; rollback leaves unreachable data.
        self.slots[key.slot].control_frames[self.front ^ 1] = frame;
    }
    fn bindRecipient(self: *Workspace, index: usize, key: Key) !void {
        if (!self.building) return error.NoFrame;
        if (self.closed or !self.current(key)) return error.StaleTextField;
        if (index >= max_hits) return error.TooManyControls;
        const bank = &self.banks[self.front ^ 1];
        if (bank.marks[index].serial != 0) return error.DuplicateId;
        for (bank.marks[0..bank.len]) |mark| if (mark.serial == key.serial and mark.slot == key.slot) return error.DuplicateId;
        bank.marks[index] = .{ .serial = key.serial, .slot = key.slot, .kind = try self.kind(key) };
        bank.len = @max(bank.len, index + 1);
    }
    pub fn validateFrame(self: *Workspace, hits: anytype) !void {
        if (self.frame_failure) |err| return err;
        if (!self.building) return error.NoFrame;
        const bank = &self.banks[self.front ^ 1];
        if (hits.len > max_hits or bank.len > hits.len) return error.InvalidTextFieldFrame;
        for (bank.marks[0..bank.len], 0..) |mark, i| if (mark.serial != 0) {
            if (mark.slot >= self.slots.len) return error.InvalidTextFieldFrame;
            const value = self.slots[mark.slot];
            if (value.id != hits[i].id or !self.current(.{ .epoch = self.epoch, .serial = mark.serial, .id = hits[i].id, .slot = mark.slot })) return error.StaleTextField;
        };
    }
    pub fn commitFrame(self: *Workspace, hits: usize) void {
        std.debug.assert(self.building and hits <= max_hits and self.publication != std.math.maxInt(u64));
        self.banks[self.front ^ 1].len = hits;
        self.front ^= 1;
        self.publication += 1;
        self.building = false;
    }
    pub fn cancelFrame(self: *Workspace) void {
        self.building = false;
        self.frame_failure = null;
    }
    pub fn rollback(self: *Workspace, length: usize) void {
        if (!self.building or length > max_hits) return;
        const bank = &self.banks[self.front ^ 1];
        if (length < bank.len) {
            @memset(bank.marks[length..bank.len], .{});
            bank.len = length;
        }
    }
    /// Only the current candidate can provide its own semantic action route.
    /// An old front or a reused ID does not retain the retired registration.
    pub fn pendingRegistered(self: *Workspace, hits: anytype, id: u64) bool {
        _ = self.pendingKey(hits, id, .text) catch return false;
        return true;
    }
    pub fn pendingControlRegistered(self: *Workspace, hits: anytype, id: u64) bool {
        _ = self.pendingKey(hits, id, .control) catch return false;
        return true;
    }
    pub fn pendingKey(self: *Workspace, hits: anytype, id: u64, expected: Kind) !Key {
        if (!self.building or self.closed or self.frame_failure != null) return error.StaleTextField;
        const bank = &self.banks[self.front ^ 1];
        for (hits, 0..) |hit, i| if (hit.id == id) {
            if (i >= bank.len) return error.StaleTextField;
            const mark = bank.marks[i];
            const key: Key = .{ .epoch = self.epoch, .serial = mark.serial, .id = id, .slot = mark.slot };
            try self.requireKind(key, expected);
            return key;
        };
        return error.StaleTextField;
    }
    pub fn byId(self: *Workspace, hits: anytype, id: u64) !Key {
        for (hits, 0..) |hit, i| if (hit.id == id) return self.accepted(i, id);
        return error.StaleTextField;
    }
    pub fn matchesToken(self: *Workspace, key: Key, candidate: ?z.TextClientToken) bool {
        const value = self.token(key) catch return false;
        return value != null and std.meta.eql(value, candidate);
    }
    /// Nonzero retired marks remain distinguishable from ordinary hits.
    pub fn marked(self: *const Workspace, index: usize) bool {
        const bank = &self.banks[self.front];
        return index < bank.len and bank.marks[index].serial != 0;
    }
    pub fn publishedKind(self: *const Workspace, index: usize) !Kind {
        if (!self.marked(index)) return error.StaleTextField;
        return self.banks[self.front].marks[index].kind;
    }
    pub fn accepted(self: *Workspace, index: usize, id: u64) !Key {
        const key = try self.publishedKey(index, id);
        if (!self.current(key)) return error.StaleTextField;
        return key;
    }
    /// Only a live control marked in the accepted bank yields a receipt. Slot
    /// reuse resets both banks, while the retired mark keeps its old serial.
    pub fn controlFrame(self: *Workspace, key: Key) !ControlFrame {
        try self.requireKind(key, .control);
        const bank = &self.banks[self.front];
        for (bank.marks[0..bank.len]) |mark| if (mark.kind == .control and mark.serial == key.serial and mark.slot == key.slot) return self.slots[key.slot].control_frames[self.front];
        return error.UnpublishedControlFrame;
    }
    /// The visual front retains identity after callback withdrawal. This does
    /// not borrow a callback or grant action authority to a retired recipient.
    pub fn publishedKey(self: *const Workspace, index: usize, id: u64) !Key {
        const bank = &self.banks[self.front];
        if (index >= bank.len) return error.StaleTextField;
        const mark = bank.marks[index];
        if (mark.serial == 0 or mark.slot >= self.slots.len) return error.StaleTextField;
        const key: Key = .{ .epoch = self.epoch, .serial = mark.serial, .id = id, .slot = mark.slot };
        return key;
    }
};

pub const Borrow = struct {
    workspace: ?*Workspace,
    key: Key,
    pub fn registration(self: *const Borrow) !Registration {
        const owner = self.workspace orelse return error.StaleTextField;
        if (!owner.current(self.key)) return error.StaleTextField;
        try owner.requireKind(self.key, .text);
        return (try owner.lookupSlot(self.key)).registration.?.text;
    }
    pub fn kind(self: *const Borrow) !Kind {
        const owner = self.workspace orelse return error.StaleTextField;
        return owner.kind(self.key);
    }
    pub fn control(self: *const Borrow) !ControlRegistration {
        const owner = self.workspace orelse return error.StaleTextField;
        try owner.requireKind(self.key, .control);
        return (try owner.lookupSlot(self.key)).registration.?.control;
    }
    pub fn end(self: *Borrow) void {
        const owner = self.workspace orelse return;
        self.workspace = null;
        const value = owner.lookupSlot(self.key) catch unreachable;
        std.debug.assert(value.pins != 0);
        value.pins -= 1;
        owner.release();
    }
};

const Probe = struct {
    fn focus(_: *anyopaque, _: *EventScope) !z.TextClientToken {
        return error.NotBound;
    }
    fn blur(_: *anyopaque, _: z.Window) !void {}
    fn input(_: *anyopaque, _: *EventScope, _: z.Event) !Result {
        return .{};
    }
    fn action(_: *anyopaque, _: *EventScope, _: Action) !Result {
        return .{};
    }
    fn registration(context: *anyopaque) Registration {
        return .{ .context = context, .focus = focus, .blur = blur, .input = input, .action = action };
    }
};
const TestHit = struct { id: u64 };
const ControlProbe = struct {
    fn focus(_: *anyopaque, _: *EventScope) !void {}
    fn blur(_: *anyopaque, _: z.Window) !void {}
    fn input(_: *anyopaque, _: *EventScope, _: z.Event) !ControlResult {
        return .{};
    }
    fn action(_: *anyopaque, _: *EventScope, _: ControlAction) !ControlResult {
        return .{};
    }
    fn registration(context: *anyopaque) ControlRegistration {
        return .{ .context = context, .focus = focus, .blur = blur, .input = input, .action = action };
    }
};

test "mixed recipients enforce typed borrows tokens bindings and semantic ownership" {
    var context: u8 = 0;
    const owner = try Workspace.create(std.testing.allocator, 10, .{ .fields = 2 }, 0);
    defer owner.release();
    const text = try owner.register(1, Probe.registration(&context));
    const control = try owner.registerControl(2, ControlProbe.registration(&context));
    var text_borrow = try owner.borrow(text);
    defer text_borrow.end();
    var control_borrow = try owner.borrow(control);
    defer control_borrow.end();
    try std.testing.expectEqual(Kind.text, try text_borrow.kind());
    try std.testing.expectEqual(Kind.control, try control_borrow.kind());
    try std.testing.expectError(error.InvalidRecipientKind, text_borrow.control());
    try std.testing.expectError(error.InvalidRecipientKind, control_borrow.registration());
    try std.testing.expectError(error.InvalidRecipientKind, owner.token(control));
    try std.testing.expectError(error.InvalidRecipientKind, owner.setToken(control, null));
    try owner.beginFrame();
    try std.testing.expectError(error.InvalidRecipientKind, owner.bind(1, control));
    try std.testing.expectError(error.InvalidRecipientKind, owner.bindControl(0, text));
    try owner.bind(0, text);
    try owner.bindControl(1, control);
    const hits = [_]TestHit{ .{ .id = 1 }, .{ .id = 2 } };
    try std.testing.expect(owner.pendingRegistered(&hits, 1));
    try std.testing.expect(!owner.pendingRegistered(&hits, 2));
    try std.testing.expect(!owner.pendingControlRegistered(&hits, 1));
    try std.testing.expect(owner.pendingControlRegistered(&hits, 2));
    try std.testing.expectError(error.Busy, owner.closeKind(.text));
    try std.testing.expectError(error.Busy, owner.reopenKind(.control));
    try owner.validateFrame(&hits);
    owner.commitFrame(2);
}

test "closing text kind preserves controls while reopening cannot revive retired identity" {
    var context: u8 = 0;
    const owner = try Workspace.create(std.testing.allocator, 11, .{ .fields = 3 }, 0);
    defer owner.release();
    const text = try owner.register(1, Probe.registration(&context));
    const control = try owner.registerControl(2, ControlProbe.registration(&context));
    try owner.beginFrame();
    try owner.bind(0, text);
    try owner.bindControl(1, control);
    owner.commitFrame(2);
    var old = try owner.borrow(text);
    defer old.end();
    try owner.closeKind(.text);
    try std.testing.expect(!owner.current(text) and owner.current(control));
    try std.testing.expectError(error.StaleTextField, old.registration());
    try std.testing.expectError(error.TextFieldsClosed, owner.register(1, Probe.registration(&context)));
    try std.testing.expectEqualDeep(text, try owner.publishedKey(0, 1));
    try std.testing.expectError(error.StaleTextField, owner.accepted(0, 1));
    try std.testing.expectEqualDeep(control, try owner.accepted(1, 2));
    try owner.reopenKind(.text);
    const replacement = try owner.register(1, Probe.registration(&context));
    try std.testing.expect(replacement.slot != text.slot and replacement.serial > text.serial);
    try std.testing.expectError(error.StaleTextField, old.registration());
    try std.testing.expect(!owner.current(text));
    owner.close();
    try std.testing.expect(!owner.current(control) and !owner.current(replacement));
    try owner.reopenKind(.text);
    try std.testing.expectError(error.TextFieldsClosed, owner.registerControl(2, ControlProbe.registration(&context)));
    const next = try owner.register(1, Probe.registration(&context));
    try std.testing.expect(next.serial > replacement.serial);
    try owner.reopenKind(.control);
    const next_control = try owner.registerControl(2, ControlProbe.registration(&context));
    try std.testing.expect(next_control.serial > next.serial);
    try std.testing.expect(!owner.current(control));
}

test "entered control callback withdrawal and same id replacement invalidate the captured borrow" {
    const Self = struct {
        owner: *Workspace,
        key: Key,
        replacement: ?Key = null,
        callbacks: usize = 0,
        fn replace(ptr: *anyopaque, scope: *EventScope, _: ControlAction) !ControlResult {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try scope.validate();
            self.callbacks += 1;
            try std.testing.expect(!try self.owner.unregister(self.key));
            self.replacement = try self.owner.registerControl(self.key.id, ControlProbe.registration(ptr));
            try std.testing.expectError(error.StaleTextField, scope.validate());
            return .{ .handled = true, .changed = true };
        }
        fn check(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.owner.requireKind(self.key, .control);
        }
    };
    const owner = try Workspace.create(std.testing.allocator, 12, .{ .fields = 2 }, 0);
    defer owner.release();
    var state: Self = .{ .owner = owner, .key = undefined };
    var registration = ControlProbe.registration(&state);
    registration.action = Self.replace;
    state.key = try owner.registerControl(7, registration);
    var borrow = try owner.borrow(state.key);
    defer borrow.end();
    var entered: ScopeState = .{ .window = undefined, .context = &state, .check = Self.check };
    const callback = try borrow.control();
    const result = try callback.action(callback.context, entered.scope(), .focus);
    try std.testing.expect(result.handled and result.changed);
    try std.testing.expectEqual(@as(usize, 1), state.callbacks);
    try std.testing.expectError(error.StaleTextField, borrow.control());
    try std.testing.expect(state.replacement.?.slot != state.key.slot and state.replacement.?.serial > state.key.serial);
    try std.testing.expect(owner.current(state.replacement.?));
    // A captured request cannot repair itself by resolving the replacement ID.
    try std.testing.expectError(error.StaleTextField, owner.borrow(state.key));
}
test "retired field slots cannot borrow freed contexts from old accepted marks" {
    var first: u8 = 1;
    var second: u8 = 2;
    const owner = try Workspace.create(std.testing.allocator, 1, .{ .fields = 1 }, 0);
    defer owner.release();
    const a = try owner.register(7, Probe.registration(&first));
    try owner.beginFrame();
    try owner.bind(0, a);
    try owner.validateFrame(&[_]TestHit{.{ .id = 7 }});
    owner.commitFrame(1);
    var pin = try owner.borrow(a);
    try std.testing.expect(!try owner.unregister(a));
    try std.testing.expectError(error.StaleTextField, pin.registration());
    try std.testing.expectError(error.TextFieldsFull, owner.register(7, Probe.registration(&second)));
    pin.end();
    const b = try owner.register(7, Probe.registration(&second));
    try std.testing.expect(b.serial != a.serial);
    try std.testing.expect(owner.marked(0));
    try std.testing.expectError(error.StaleTextField, owner.accepted(0, 7));
    try owner.beginFrame();
    try owner.bind(0, b);
    try owner.validateFrame(&[_]TestHit{.{ .id = 7 }});
    owner.commitFrame(1);
    var current = try owner.borrow(try owner.accepted(0, 7));
    try std.testing.expect((try current.registration()).context == @as(*anyopaque, &second));
    current.end();
}
test "field candidate rollback keeps the old front and ordinary marks stay ordinary" {
    var context: u8 = 0;
    const owner = try Workspace.create(std.testing.allocator, 2, .{ .fields = 2 }, 1);
    defer owner.release();
    const a = try owner.register(1, Probe.registration(&context));
    try std.testing.expect(!owner.marked(0));
    try owner.beginFrame();
    try owner.bind(0, a);
    try std.testing.expectError(error.InvalidTextFieldFrame, owner.validateFrame(@as([]const TestHit, &.{})));
    owner.cancelFrame();
    try std.testing.expect(!owner.marked(0));
    try owner.beginFrame();
    try owner.bind(1, a);
    try owner.validateFrame(&[_]TestHit{ .{ .id = 2 }, .{ .id = 1 } });
    owner.commitFrame(2);
    try std.testing.expect(!owner.marked(0) and owner.marked(1));
    owner.close();
    try std.testing.expect(owner.marked(1));
    try std.testing.expectError(error.StaleTextField, owner.accepted(1, 1));
    // A closed registry still permits a normal visual frame to remove marks.
    try owner.beginFrame();
    try owner.validateFrame(&[_]TestHit{.{ .id = 2 }});
    owner.commitFrame(1);
    try std.testing.expect(!owner.marked(0));
}
test "field registration publication and allocation limits are transactional" {
    var context: u8 = 0;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try std.testing.expectError(error.InvalidTextFieldLimits, Workspace.create(failing.allocator(), 0, .{}, 0));
    try std.testing.expectError(error.TextFieldBudgetExceeded, Workspace.create(failing.allocator(), 1, .{ .bytes = 1 }, 0));
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    const owner = try Workspace.create(failing.allocator(), 3, .{}, 0);
    defer owner.release();
    owner.serial = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, owner.register(1, Probe.registration(&context)));
    owner.publication = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, owner.beginFrame());
    try std.testing.expect(!owner.building and owner.banks[owner.front].len == 0);
}

test "semantic action ownership requires the current pending registration serial" {
    var context: u8 = 0;
    const owner = try Workspace.create(std.testing.allocator, 1, .{ .fields = 1 }, 0);
    defer owner.release();
    const a = try owner.register(7, Probe.registration(&context));
    const hits = [_]TestHit{.{ .id = 7 }};
    try owner.beginFrame();
    try std.testing.expect(!owner.pendingRegistered(&hits, 7));
    try owner.bind(0, a);
    try std.testing.expect(owner.pendingRegistered(&hits, 7));
    try std.testing.expect(!owner.pendingRegistered(&hits, 8));
    owner.commitFrame(1);
    try std.testing.expect(!owner.pendingRegistered(&hits, 7));
    try owner.beginFrame();
    try std.testing.expect(!owner.pendingRegistered(&hits, 7));
    try owner.bind(0, a);
    try std.testing.expect(try owner.unregister(a));
    const b = try owner.register(7, Probe.registration(&context));
    try std.testing.expect(b.serial != a.serial);
    try std.testing.expect(!owner.pendingRegistered(&hits, 7));
    owner.cancelFrame();
    try owner.beginFrame();
    try owner.bind(0, b);
    try std.testing.expect(owner.pendingRegistered(&hits, 7));
    owner.rollback(0);
    try std.testing.expect(!owner.pendingRegistered(&hits, 7));
}

test "control visual receipt follows accepted frames through failed scroll and omitted frames" {
    var context: u8 = 0;
    const owner = try Workspace.create(std.testing.allocator, 14, .{ .fields = 1 }, 0);
    defer owner.release();
    const key = try owner.registerControl(7, ControlProbe.registration(&context));
    const hits = [_]TestHit{.{ .id = 7 }};
    try std.testing.expectError(error.UnpublishedControlFrame, owner.controlFrame(key));
    try owner.beginFrame();
    try owner.bindControlFrame(0, key, .{ .model = 3, .scroll = 80 });
    try owner.validateFrame(&hits);
    owner.commitFrame(1);
    try owner.beginFrame();
    try owner.bindControlFrame(0, key, .{ .model = 4, .scroll = 160 });
    try std.testing.expectEqualDeep(ControlFrame{ .model = 3, .scroll = 80 }, try owner.controlFrame(key));
    try std.testing.expectError(error.InvalidTextFieldFrame, owner.validateFrame(@as([]const TestHit, &.{})));
    owner.cancelFrame();
    // A click at viewport y=7 still addresses content y=87 while a newer scroll
    // is pending; selection revisions deliberately are not part of the receipt.
    try std.testing.expectEqual(@as(f64, 87), (try owner.controlFrame(key)).scroll + 7);
    try owner.beginFrame();
    try owner.bindControlFrame(0, key, .{ .model = 4, .scroll = 160 });
    try owner.validateFrame(&hits);
    owner.commitFrame(1);
    try std.testing.expectEqualDeep(ControlFrame{ .model = 4, .scroll = 160 }, try owner.controlFrame(key));
    try owner.beginFrame();
    try owner.validateFrame(@as([]const TestHit, &.{}));
    owner.commitFrame(0);
    try std.testing.expectError(error.UnpublishedControlFrame, owner.controlFrame(key));
}

test "control receipt validation duplicate binding and rollback are transactional" {
    var context: u8 = 0;
    const owner = try Workspace.create(std.testing.allocator, 15, .{ .fields = 1 }, 0);
    defer owner.release();
    const key = try owner.registerControl(7, ControlProbe.registration(&context));
    try owner.beginFrame();
    for ([_]f64{ -1, std.math.inf(f64), std.math.nan(f64) }) |bad| {
        try std.testing.expectError(error.InvalidControlFrame, owner.bindControlFrame(0, key, .{ .model = 1, .scroll = bad }));
        try std.testing.expectEqual(@as(usize, 0), owner.banks[owner.front ^ 1].len);
    }
    try owner.bindControlFrame(0, key, .{ .model = 1, .scroll = 12 });
    try std.testing.expectError(error.DuplicateId, owner.bindControlFrame(1, key, .{ .model = 2, .scroll = 99 }));
    try std.testing.expectError(error.DuplicateId, owner.bindControlFrame(0, key, .{ .model = 2, .scroll = 99 }));
    owner.commitFrame(1);
    try std.testing.expectEqualDeep(ControlFrame{ .model = 1, .scroll = 12 }, try owner.controlFrame(key));
    try owner.beginFrame();
    try owner.bindControlFrame(0, key, .{ .model = 2, .scroll = 35 });
    owner.rollback(0);
    try owner.bindControlFrame(0, key, .{ .model = 3, .scroll = 48 });
    owner.commitFrame(1);
    try std.testing.expectEqualDeep(ControlFrame{ .model = 3, .scroll = 48 }, try owner.controlFrame(key));
}

test "receipt scope pins old callback while publication or rebind revokes entered authority" {
    const Entered = struct {
        owner: *Workspace,
        key: Key,
        publication: u64,
        fn check(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.owner.publication != self.publication) return error.StaleTextField;
            try self.owner.requireKind(self.key, .control);
        }
    };
    var context: u8 = 0;
    const owner = try Workspace.create(std.testing.allocator, 16, .{ .fields = 2 }, 0);
    defer owner.release();
    const key = try owner.registerControl(7, ControlProbe.registration(&context));
    try owner.beginFrame();
    try owner.bindControlFrame(0, key, .{ .model = 5, .scroll = 22 });
    owner.commitFrame(1);
    var pin = try owner.borrow(key);
    defer pin.end();
    var entered: Entered = .{ .owner = owner, .key = key, .publication = owner.publication };
    var state: ScopeState = .{ .window = undefined, .context = &entered, .check = Entered.check, .control_frame = try owner.controlFrame(key), .publication = owner.publication };
    try std.testing.expectEqualDeep(ControlFrame{ .model = 5, .scroll = 22 }, try state.scope().controlFrame());
    try std.testing.expectEqual(owner.publication, try state.scope().controlPublication());
    try owner.beginFrame();
    try owner.bindControlFrame(0, key, .{ .model = 6, .scroll = 44 });
    owner.cancelFrame();
    try std.testing.expectEqual(@as(u64, 5), (try state.scope().controlFrame()).model);
    try std.testing.expect(!try owner.unregister(key));
    const replacement = try owner.registerControl(7, ControlProbe.registration(&context));
    try std.testing.expect(replacement.slot != key.slot);
    try std.testing.expectError(error.StaleTextField, state.scope().controlFrame());
    try std.testing.expectError(error.StaleTextField, state.scope().controlPublication());
    try std.testing.expectError(error.UnpublishedControlFrame, owner.controlFrame(replacement));
    try owner.beginFrame();
    try owner.bindControlFrame(0, replacement, .{ .model = 8, .scroll = 3 });
    owner.commitFrame(1);
    try std.testing.expectError(error.StaleTextField, state.scope().controlFrame());
}

test "closing and reopening cannot expose a prior slot receipt" {
    var context: u8 = 0;
    const owner = try Workspace.create(std.testing.allocator, 17, .{ .fields = 1 }, 0);
    defer owner.release();
    const key = try owner.registerControl(7, ControlProbe.registration(&context));
    try owner.beginFrame();
    try owner.bindControlFrame(0, key, .{ .model = 9, .scroll = 99 });
    owner.commitFrame(1);
    try owner.closeKind(.control);
    try owner.reopenKind(.control);
    const replacement = try owner.registerControl(7, ControlProbe.registration(&context));
    try std.testing.expectEqual(key.slot, replacement.slot);
    try std.testing.expect(replacement.serial != key.serial);
    try std.testing.expectError(error.StaleTextField, owner.controlFrame(key));
    try std.testing.expectError(error.UnpublishedControlFrame, owner.controlFrame(replacement));
    try owner.beginFrame();
    try owner.bindControl(0, replacement);
    owner.commitFrame(1);
    try std.testing.expectEqualDeep(ControlFrame{}, try owner.controlFrame(replacement));
    std.debug.print("receipt: Slot={d} Mark={d} registry4={d} registry8={d} bytes\n", .{ @sizeOf(Slot), @sizeOf(Mark), try Workspace.requiredBytes(.{ .fields = 4 }, 0), try Workspace.requiredBytes(.{ .fields = 8 }, 0) });
}
