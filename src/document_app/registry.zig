const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const id = @import("identity.zig");

pub const DocumentId = struct {
    index: u32,
    generation: u32,
    pub fn eql(self: DocumentId, other: DocumentId) bool {
        return self.index == other.index and self.generation == other.generation;
    }
};
pub const Kind = union(enum) { file: id.Identity, untitled: u32 };

/// Stable per-document crash-recovery file stem: "f" plus a path hash for
/// file documents, "u" plus the untitled serial otherwise.
pub const RecoveryName = struct {
    len: u8 = 0,
    bytes: [24]u8 = undefined,
    pub fn slice(self: *const RecoveryName) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn eql(self: *const RecoveryName, other: *const RecoveryName) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
    pub fn forKind(kind: *const Kind) RecoveryName {
        var name: RecoveryName = .{};
        const text = switch (kind.*) {
            .file => |*identity| blk: {
                var hasher = std.hash.Wyhash.init(0x5a1c_7d0e);
                for (identity.path.slice()) |byte| hasher.update(&.{if (builtin.os.tag == .windows) std.ascii.toLower(byte) else byte});
                break :blk std.fmt.bufPrint(&name.bytes, "f{x:0>16}", .{hasher.final()}) catch unreachable;
            },
            .untitled => |serial| std.fmt.bufPrint(&name.bytes, "u{d}", .{serial}) catch unreachable,
        };
        name.len = @intCast(text.len);
        return name;
    }
    pub fn parse(text: []const u8) !RecoveryName {
        if (text.len < 2 or text.len > 24 or (text[0] != 'f' and text[0] != 'u')) return error.InvalidName;
        for (text[1..]) |byte| if (!std.ascii.isHex(byte)) return error.InvalidName;
        var name: RecoveryName = .{ .len = @intCast(text.len) };
        @memcpy(name.bytes[0..text.len], text);
        return name;
    }
};

/// Delays are measured on the caller's clock (`now` arguments, nanoseconds).
/// The registry never arms a timer: the host schedules `nextDeadline`.
pub const Policy = struct {
    autosave: bool = true,
    /// Quiet period after the last edit before a file document is saved.
    autosave_delay_ns: u64 = 2 * std.time.ns_per_s,
    /// Upper bound from the first unsaved edit, so continuous typing still saves.
    autosave_max_delay_ns: u64 = 30 * std.time.ns_per_s,
    recovery: bool = true,
    /// Quiet period before unsaved content, including untitled documents, is snapshotted.
    snapshot_delay_ns: u64 = 5 * std.time.ns_per_s,
    snapshot_max_delay_ns: u64 = 60 * std.time.ns_per_s,
};

/// Notifications run on the owner thread, usually inside a close callback.
/// They must not block, wait for a dialog or run a nested loop: show an
/// asynchronous prompt and call `discard`/save, then request the close again.
pub const Handlers = struct {
    context: *anyopaque,
    close_blocked: *const fn (*anyopaque, *Registry, DocumentId, z.CloseReason) void,
    /// `blocking` lists every document still holding up the quit.
    quit_blocked: *const fn (*anyopaque, *Registry) void,
    /// Dirty, conflict or identity state changed; refresh titles or menus.
    changed: ?*const fn (*anyopaque, *Registry, DocumentId) void = null,
    released: ?*const fn (*anyopaque, *Registry, Released) void = null,
};
/// A slot was released after its window's on_closed. `unsaved` means the
/// window was destroyed while dirty without a discard decision (forced close
/// or forced quit): keep its snapshot for recovery. Otherwise delete it.
pub const Released = struct { document: DocumentId, recovery: RecoveryName, snapshot: bool, unsaved: bool };

pub const Slot = struct {
    generation: u32 = 0,
    phase: enum { free, reserved, open } = .free,
    kind: Kind = .{ .untitled = 0 },
    window: ?z.Window = null,
    revision: u64 = 0,
    saved_revision: u64 = 0,
    stamp: ?id.Stamp = null,
    saving: ?u64 = null,
    snapshotting: ?u64 = null,
    /// Revision held by the snapshot file on disk, if any.
    snapshot: ?u64 = null,
    snapshot_name: RecoveryName = .{},
    discard_revision: ?u64 = null,
    pending_close: ?z.CloseReason = null,
    conflict: bool = false,
    dirty_since: i128 = 0,
    last_edit: i128 = 0,
    fn dirty(self: *const Slot) bool {
        return self.revision != self.saved_revision;
    }
    fn blocks(self: *const Slot) bool {
        return self.phase == .open and self.dirty() and self.discard_revision != self.revision;
    }
};

pub const Claim = union(enum) {
    /// Load the file, create its window, then `attach`; `cancel` on failure.
    reserved: DocumentId,
    /// Already open or opening; `reveal` focuses its window when it has one.
    existing: DocumentId,
};
pub const Info = struct {
    kind: *const Kind,
    window: ?z.Window,
    dirty: bool,
    conflict: bool,
    saving: bool,
    revision: u64,
    stamp: ?id.Stamp,
    pending_close: ?z.CloseReason,
};
pub const SaveTicket = struct {
    document: DocumentId,
    revision: u64,
    /// Pass to `Files.save`; null when overwriting or saving to a new target.
    expected: ?id.Stamp,
    path: id.Path,
    target: ?id.Identity = null,
};
pub const SaveOutcome = struct {
    clean: bool,
    /// The close or quit that was waiting for this document; request it again.
    retry_close: ?z.CloseReason,
    /// Snapshot file made obsolete by this save; delete it on a worker.
    obsolete_snapshot: ?RecoveryName,
};
pub const SnapshotTicket = struct { document: DocumentId, revision: u64, name: RecoveryName };
pub const SnapshotOutcome = enum { kept, obsolete };

/// One window per document. Owner-thread state for identity, dirty revisions,
/// close/quit preflight, autosave and recovery scheduling. Storage is the
/// caller's fixed slot array; nothing allocates. The registry must stay at a
/// stable address and outlive every window it handles through on_closed.
pub const Registry = struct {
    app: *z.App,
    slots: []Slot,
    policy: Policy,
    handlers: Handlers,
    untitled_serial: u32 = 0,
    quit_pending: bool = false,

    pub fn init(app: *z.App, slots: []Slot, policy: Policy, handlers: Handlers) Registry {
        for (slots) |*slot| slot.* = .{};
        return .{ .app = app, .slots = slots, .policy = policy, .handlers = handlers };
    }
    fn get(self: *Registry, document: DocumentId) !*Slot {
        self.app.assertOwner();
        if (document.index >= self.slots.len) return error.StaleDocument;
        const slot = &self.slots[document.index];
        if (slot.phase == .free or slot.generation != document.generation) return error.StaleDocument;
        return slot;
    }
    fn handle(self: *Registry, slot: *const Slot) DocumentId {
        return .{ .index = @intCast((@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot)), .generation = slot.generation };
    }
    fn notify(self: *Registry, slot: *const Slot) void {
        if (self.handlers.changed) |changed| changed(self.handlers.context, self, self.handle(slot));
    }
    fn allocate(self: *Registry, kind: Kind) !*Slot {
        for (self.slots) |*slot| if (slot.phase == .free) {
            const generation = slot.generation;
            slot.* = .{ .generation = generation, .phase = .reserved, .kind = kind };
            slot.snapshot_name = RecoveryName.forKind(&slot.kind);
            return slot;
        };
        return error.CapacityExceeded;
    }
    fn release(slot: *Slot) void {
        const generation = slot.generation +% 1;
        slot.* = .{ .generation = generation };
    }

    pub fn find(self: *Registry, identity: *const id.Identity) ?DocumentId {
        self.app.assertOwner();
        for (self.slots) |*slot| if (slot.phase != .free and slot.kind == .file and slot.kind.file.eql(identity)) return self.handle(slot);
        return null;
    }
    /// Resolve the identity on a worker first. Duplicate opens, including one
    /// still loading, return the existing document instead of a second window.
    pub fn claim(self: *Registry, identity: *const id.Identity) !Claim {
        if (self.find(identity)) |existing| return .{ .existing = existing };
        return .{ .reserved = self.handle(try self.allocate(.{ .file = identity.* })) };
    }
    pub fn claimUntitled(self: *Registry) !DocumentId {
        self.app.assertOwner();
        const slot = try self.allocate(.{ .untitled = self.untitled_serial + 1 });
        self.untitled_serial += 1;
        return self.handle(slot);
    }
    /// Binds the window created for a reserved document. `stamp` is the disk
    /// observation from loading; null for untitled or not-yet-saved documents.
    pub fn attach(self: *Registry, document: DocumentId, window: z.Window, stamp: ?id.Stamp) !void {
        const slot = try self.get(document);
        if (slot.phase != .reserved) return error.AlreadyAttached;
        if (window.isClosed()) return error.Closed;
        if (self.documentOf(window) != null) return error.WindowInUse;
        slot.phase = .open;
        slot.window = window;
        slot.stamp = stamp;
        if (stamp) |value| if (slot.kind == .file) {
            slot.kind.file.key = value.key;
        };
    }
    /// Drops a reservation whose load or window creation failed.
    pub fn cancel(self: *Registry, document: DocumentId) !void {
        const slot = try self.get(document);
        if (slot.phase != .reserved) return error.AlreadyAttached;
        release(slot);
    }
    /// Shows, restores and focuses the document's window. False while the
    /// document is still loading and has no window yet.
    pub fn reveal(self: *Registry, document: DocumentId) !bool {
        const slot = try self.get(document);
        const window = slot.window orelse return false;
        const state = try window.state();
        if (!state.visible) try window.perform(.show);
        if (state.minimized) try window.perform(.restore);
        try window.perform(.focus);
        return true;
    }
    pub fn documentOf(self: *Registry, window: z.Window) ?DocumentId {
        self.app.assertOwner();
        for (self.slots) |*slot| if (slot.window) |bound| {
            if (bound.app == window.app and bound.key.index == window.key.index and bound.key.generation == window.key.generation) return self.handle(slot);
        };
        return null;
    }
    pub fn info(self: *Registry, document: DocumentId) !Info {
        const slot = try self.get(document);
        return .{ .kind = &slot.kind, .window = slot.window, .dirty = slot.dirty(), .conflict = slot.conflict, .saving = slot.saving != null, .revision = slot.revision, .stamp = slot.stamp, .pending_close = slot.pending_close };
    }
    /// File name, or "Untitled N" for untitled documents.
    pub fn displayName(self: *Registry, document: DocumentId, output: []u8) ![]const u8 {
        const slot = try self.get(document);
        return switch (slot.kind) {
            .file => |*identity| blk: {
                const name = identity.path.basename();
                if (name.len > output.len) return error.NoSpaceLeft;
                @memcpy(output[0..name.len], name);
                break :blk output[0..name.len];
            },
            .untitled => |serial| std.fmt.bufPrint(output, "Untitled {d}", .{serial}),
        };
    }
    pub fn count(self: *Registry) usize {
        self.app.assertOwner();
        var total: usize = 0;
        for (self.slots) |*slot| total += @intFromBool(slot.phase != .free);
        return total;
    }

    /// Records one content change. Any discard decision is invalidated.
    pub fn edited(self: *Registry, document: DocumentId, now: i128) !void {
        const slot = try self.get(document);
        const was_dirty = slot.dirty();
        slot.revision += 1;
        slot.last_edit = now;
        if (!was_dirty) {
            slot.dirty_since = now;
            self.notify(slot);
        }
    }
    /// Content was replaced from disk (revert, or accepting an external change).
    pub fn reloaded(self: *Registry, document: DocumentId, stamp: id.Stamp) !void {
        const slot = try self.get(document);
        slot.revision += 1;
        slot.saved_revision = slot.revision;
        slot.stamp = stamp;
        slot.conflict = false;
        if (slot.kind == .file) slot.kind.file.key = stamp.key;
        self.notify(slot);
    }
    /// Marks an external change found by `Files.probe`; autosave pauses until
    /// the host reloads or overwrites.
    pub fn externallyModified(self: *Registry, document: DocumentId) !void {
        const slot = try self.get(document);
        if (slot.conflict) return;
        slot.conflict = true;
        self.notify(slot);
    }

    pub const SaveMode = enum { normal, overwrite };
    /// Starts saving the current revision. The caller serializes that revision
    /// and runs `Files.save(ticket.path.slice(), ..., .{ .expected = ticket.expected })`.
    pub fn beginSave(self: *Registry, document: DocumentId, mode: SaveMode) !SaveTicket {
        const slot = try self.get(document);
        if (slot.phase != .open) return error.NotAttached;
        if (slot.saving != null) return error.SaveInProgress;
        const identity = switch (slot.kind) {
            .file => |*identity| identity,
            .untitled => return error.Untitled,
        };
        if (slot.conflict and mode == .normal) return error.Conflict;
        slot.saving = slot.revision;
        return .{ .document = document, .revision = slot.revision, .expected = if (mode == .overwrite) null else slot.stamp, .path = identity.path };
    }
    /// Save to a new target resolved with `Files.resolveTarget`. Fails with
    /// AlreadyOpen when another document owns that file.
    pub fn beginSaveAs(self: *Registry, document: DocumentId, target: *const id.Identity) !SaveTicket {
        const slot = try self.get(document);
        if (slot.phase != .open) return error.NotAttached;
        if (slot.saving != null) return error.SaveInProgress;
        if (self.find(target)) |owner| if (!owner.eql(document)) return error.AlreadyOpen;
        slot.saving = slot.revision;
        return .{ .document = document, .revision = slot.revision, .expected = null, .path = target.path, .target = target.* };
    }
    pub fn finishSave(self: *Registry, ticket: *const SaveTicket, stamp: id.Stamp) !SaveOutcome {
        const slot = try self.get(ticket.document);
        if (slot.saving != ticket.revision) return error.StaleTicket;
        slot.saving = null;
        var obsolete: ?RecoveryName = null;
        if (ticket.target) |target| {
            if (self.find(&target)) |owner| if (!owner.eql(ticket.document)) {
                // Another window claimed the file while this save ran; keep this
                // document's previous identity rather than create a duplicate.
                return error.AlreadyOpen;
            };
            if (slot.snapshot != null) obsolete = slot.snapshot_name;
            slot.kind = .{ .file = target };
            slot.snapshot_name = RecoveryName.forKind(&slot.kind);
            slot.snapshot = null;
        }
        slot.kind.file.key = stamp.key;
        slot.stamp = stamp;
        slot.conflict = false;
        slot.saved_revision = ticket.revision;
        const clean = !slot.dirty();
        if (clean and slot.snapshot != null) {
            obsolete = slot.snapshot_name;
            slot.snapshot = null;
        }
        if (!clean) slot.dirty_since = slot.last_edit;
        const retry = if (clean) slot.pending_close else null;
        if (clean) slot.pending_close = null;
        self.notify(slot);
        return .{ .clean = clean, .retry_close = retry, .obsolete_snapshot = obsolete };
    }
    /// The save failed before replacing the file; state and any waiting close
    /// are unchanged so the host can report the error and let the user retry.
    pub fn failSave(self: *Registry, ticket: *const SaveTicket) !void {
        const slot = try self.get(ticket.document);
        if (slot.saving != ticket.revision) return error.StaleTicket;
        slot.saving = null;
    }
    /// `Files.save` returned `.conflict`: the disk no longer matches the
    /// loaded stamp. Resolve with `reloaded` or `beginSave(.overwrite)`.
    pub fn conflictSave(self: *Registry, ticket: *const SaveTicket) !void {
        try self.failSave(ticket);
        try self.externallyModified(ticket.document);
    }

    fn autosaveEligible(self: *const Registry, slot: *const Slot) bool {
        return self.policy.autosave and slot.phase == .open and slot.kind == .file and slot.dirty() and slot.saving == null and !slot.conflict;
    }
    fn snapshotEligible(self: *const Registry, slot: *const Slot) bool {
        return self.policy.recovery and slot.phase == .open and slot.dirty() and slot.snapshotting == null and slot.snapshot != slot.revision;
    }
    fn deadline(slot: *const Slot, delay: u64, max_delay: u64) i128 {
        return @min(slot.last_edit + delay, slot.dirty_since + max_delay);
    }
    fn autosaveDeadline(self: *const Registry, slot: *const Slot) ?i128 {
        return if (self.autosaveEligible(slot)) deadline(slot, self.policy.autosave_delay_ns, self.policy.autosave_max_delay_ns) else null;
    }
    fn snapshotDeadline(self: *const Registry, slot: *const Slot) ?i128 {
        return if (self.snapshotEligible(slot)) deadline(slot, self.policy.snapshot_delay_ns, self.policy.snapshot_max_delay_ns) else null;
    }
    /// Earliest autosave or snapshot deadline. Null means nothing is pending,
    /// so the host keeps no timer armed while idle.
    pub fn nextDeadline(self: *Registry) ?i128 {
        self.app.assertOwner();
        var earliest: ?i128 = null;
        for (self.slots) |*slot| for ([_]?i128{ self.autosaveDeadline(slot), self.snapshotDeadline(slot) }) |candidate| {
            if (candidate) |value| earliest = if (earliest) |current| @min(current, value) else value;
        };
        return earliest;
    }
    /// File documents whose autosave deadline has passed. Pass maxInt(i128)
    /// to flush every eligible document, for example on deactivation.
    pub fn dueAutosaves(self: *Registry, now: i128, output: []DocumentId) []DocumentId {
        self.app.assertOwner();
        var length: usize = 0;
        for (self.slots) |*slot| if (self.autosaveDeadline(slot)) |value| if (value <= now and length < output.len) {
            output[length] = self.handle(slot);
            length += 1;
        };
        return output[0..length];
    }
    pub fn dueSnapshots(self: *Registry, now: i128, output: []DocumentId) []DocumentId {
        self.app.assertOwner();
        var length: usize = 0;
        for (self.slots) |*slot| if (self.snapshotDeadline(slot)) |value| if (value <= now and length < output.len) {
            output[length] = self.handle(slot);
            length += 1;
        };
        return output[0..length];
    }
    pub fn beginSnapshot(self: *Registry, document: DocumentId) !SnapshotTicket {
        const slot = try self.get(document);
        if (slot.snapshotting != null) return error.SnapshotInProgress;
        if (!slot.dirty()) return error.Clean;
        slot.snapshotting = slot.revision;
        return .{ .document = document, .revision = slot.revision, .name = slot.snapshot_name };
    }
    /// `.obsolete` means the written file no longer protects anything (the
    /// document was saved, renamed or closed meanwhile); delete it on a worker.
    pub fn finishSnapshot(self: *Registry, ticket: *const SnapshotTicket) SnapshotOutcome {
        const slot = self.get(ticket.document) catch return .obsolete;
        if (slot.snapshotting != ticket.revision) return .obsolete;
        slot.snapshotting = null;
        if (!slot.snapshot_name.eql(&ticket.name) or !slot.dirty() or slot.saved_revision >= ticket.revision) return .obsolete;
        slot.snapshot = ticket.revision;
        return .kept;
    }
    pub fn failSnapshot(self: *Registry, ticket: *const SnapshotTicket) void {
        const slot = self.get(ticket.document) catch return;
        if (slot.snapshotting == ticket.revision) slot.snapshotting = null;
    }

    /// Accept losing the current revision's changes. A later edit revokes it.
    pub fn discard(self: *Registry, document: DocumentId) !void {
        const slot = try self.get(document);
        slot.discard_revision = slot.revision;
    }
    pub fn discardAll(self: *Registry) void {
        self.app.assertOwner();
        for (self.slots) |*slot| if (slot.blocks()) {
            slot.discard_revision = slot.revision;
        };
    }
    /// The user cancelled the prompt: forget the waiting close or quit.
    pub fn abandonClose(self: *Registry, document: DocumentId) !void {
        const slot = try self.get(document);
        if (slot.pending_close == .quit) self.abandonQuit() else slot.pending_close = null;
    }
    pub fn abandonQuit(self: *Registry) void {
        self.app.assertOwner();
        self.quit_pending = false;
        for (self.slots) |*slot| if (slot.pending_close == .quit) {
            slot.pending_close = null;
        };
    }
    /// Documents with unsaved changes and no discard decision.
    pub fn blocking(self: *Registry, output: []DocumentId) []DocumentId {
        self.app.assertOwner();
        var length: usize = 0;
        for (self.slots) |*slot| if (slot.blocks() and length < output.len) {
            output[length] = self.handle(slot);
            length += 1;
        };
        return output[0..length];
    }
    fn blockQuit(self: *Registry) void {
        self.quit_pending = true;
        for (self.slots) |*slot| if (slot.blocks()) {
            slot.pending_close = .quit;
        };
        self.handlers.quit_blocked(self.handlers.context, self);
    }
    /// Preflights every document before the App's own quit preflight, so one
    /// prompt can cover all unsaved documents and no window closes early.
    pub fn requestQuit(self: *Registry) z.App.QuitResult {
        self.app.assertOwner();
        for (self.slots) |*slot| if (slot.blocks()) {
            self.blockQuit();
            return .cancelled;
        };
        self.quit_pending = false;
        return self.app.requestQuit();
    }
    pub fn allowClose(self: *Registry, window: z.Window, reason: z.CloseReason) z.CloseDecision {
        const document = self.documentOf(window) orelse return .allow;
        const slot = self.get(document) catch return .allow;
        if (!slot.blocks()) return .allow;
        if (reason == .quit) {
            self.blockQuit();
        } else {
            slot.pending_close = reason;
            self.handlers.close_blocked(self.handlers.context, self, document, reason);
        }
        return .cancel;
    }
    /// Call from the window's on_closed: the slot is released and its
    /// recovery snapshot reported. Windows without a document are ignored.
    pub fn closed(self: *Registry, window: z.Window) void {
        const document = self.documentOf(window) orelse return;
        const slot = &self.slots[document.index];
        const released: Released = .{ .document = document, .recovery = slot.snapshot_name, .snapshot = slot.snapshot != null or slot.snapshotting != null, .unsaved = slot.blocks() };
        release(slot);
        if (self.handlers.released) |notify_released| notify_released(self.handlers.context, self, released);
    }
    fn onClose(context: *anyopaque, window: z.Window, reason: z.CloseReason) z.CloseDecision {
        const self: *Registry = @ptrCast(@alignCast(context));
        return self.allowClose(window, reason);
    }
    fn onClosed(context: *anyopaque, window: z.Window) void {
        const self: *Registry = @ptrCast(@alignCast(context));
        self.closed(window);
    }
    /// Window handlers for hosts without their own; others call allowClose/closed.
    pub fn closeHandler(self: *Registry) z.CloseHandler {
        return .{ .context = self, .request = onClose };
    }
    pub fn closedHandler(self: *Registry) z.ClosedHandler {
        return .{ .context = self, .notify = onClosed };
    }
};
