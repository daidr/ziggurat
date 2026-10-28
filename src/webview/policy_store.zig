const std = @import("std");
const zio = @import("ziggurat_io");
const schemes = @import("schemes.zig");
const permissions = @import("permissions.zig");
const downloads = @import("downloads.zig");

pub const Scope = struct { namespace: [16]u8, policy_epoch: u64 };
pub const Limits = struct {
    rules: usize = 256,
    owned_bytes: usize = 128 * 1024,
    file_bytes: usize = 128 * 1024,
    max_ttl_seconds: u64 = 30 * 24 * 60 * 60,
    pub fn validate(self: Limits) !void {
        if (self.rules == 0 or self.rules > 1024 or self.owned_bytes < @sizeOf(State) or self.owned_bytes > 1024 * 1024 or self.file_bytes < header_size or self.file_bytes > 1024 * 1024 or self.max_ttl_seconds == 0 or self.max_ttl_seconds > 10 * 365 * 24 * 60 * 60) return error.InvalidPolicyLimits;
    }
};
pub const Decision = enum(u8) { ask, deny, allow };
pub const Subject = union(enum) { permission: permissions.Kind, download };
pub const Key = struct { origin: []const u8, subject: Subject };
pub const DownloadConstraints = struct {
    max_known_bytes: u64 = 64 * 1024 * 1024,
    max_received_bytes: u64 = 64 * 1024 * 1024,
    allow_unknown_length: bool = false,
    /// Application-defined identity, not an absolute path or directory grant.
    folder_key: ?u64 = null,
    /// Pure data intersection, not a native mutation. The host applies known/
    /// unknown gates before accept and observes/cancels the received soft limit,
    /// or configures its View with these same narrower limits in advance.
    pub fn intersect(self: DownloadConstraints, capability: downloads.Limits) downloads.Limits {
        return .{ .max_active = capability.max_active, .max_known_bytes = @min(self.max_known_bytes, capability.max_known_bytes), .max_received_bytes = @min(self.max_received_bytes, capability.max_received_bytes), .allow_unknown_length = self.allow_unknown_length and capability.allow_unknown_length };
    }
};
pub const Action = union(enum) {
    permission: struct { kind: permissions.Kind, decision: Decision },
    download: struct { decision: Decision, constraints: DownloadConstraints = .{} },
    pub fn subject(self: Action) Subject {
        return switch (self) {
            .permission => |p| .{ .permission = p.kind },
            .download => .download,
        };
    }
    pub fn decision(self: Action) Decision {
        return switch (self) {
            .permission => |p| p.decision,
            .download => |p| p.decision,
        };
    }
};
pub const Rule = struct { origin: []const u8, issued_at: i64, expires_at: i64, action: Action };
const Entry = struct { rule: Rule, revision: u64 };
pub const Stats = struct { rules: usize, owned_bytes: usize, mutation_peak_bytes: usize, revision: u64 };
/// Owns its exact key bytes; mutation or loading another Store cannot revive it.
/// The application must validate immediately before its native decide/resolve.
pub const DecisionLease = struct {
    store_identity: u64,
    scope: Scope,
    origin: [schemes.origin_limit]u8 = undefined,
    origin_length: u16,
    rule_revision: u64,
    issued_at: i64,
    expires_at: i64,
    action: Action,
    pub fn key(self: *const DecisionLease) Key {
        return .{ .origin = self.origin[0..self.origin_length], .subject = self.action.subject() };
    }
};
pub const LookupStats = struct { comparisons: usize = 0 };
const State = struct {
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    owner: std.Thread.Id,
    adopted: bool,
    identity: u64,
    scope: Scope,
    limits: Limits,
    revision: u64 = 0,
    mutation_peak_bytes: usize = @sizeOf(State),
    storage: ?[]align(@alignOf(Entry)) u8 = null,
    entries: []Entry = &.{},
};
var next_identity: std.atomic.Value(u64) = .init(1);
fn identity() !u64 {
    var current = next_identity.load(.monotonic);
    while (current != std.math.maxInt(u64)) {
        if (next_identity.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |updated| current = updated else return current;
    }
    return error.PolicyIdentityExhausted;
}
fn state(store: *const Store) *State {
    return @ptrCast(@alignCast(@constCast(store)));
}
fn sameScope(a: Scope, b: Scope) bool {
    return a.policy_epoch == b.policy_epoch and std.mem.eql(u8, &a.namespace, &b.namespace);
}
fn code(subject: Subject) u8 {
    return switch (subject) {
        .permission => |kind| @intCast(@backingInt(kind)),
        .download => 14,
    };
}
fn compare(a: Key, b: Key) std.math.Order {
    const order = std.mem.order(u8, a.origin, b.origin);
    return if (order == .eq) std.math.order(code(a.subject), code(b.subject)) else order;
}
fn entryKey(entry: Entry) Key {
    return .{ .origin = entry.rule.origin, .subject = entry.rule.action.subject() };
}
fn lowerBound(s: *const State, key: Key, metrics: ?*LookupStats) usize {
    var low: usize = 0;
    var high = s.entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (metrics) |value| value.comparisons += 1;
        if (compare(entryKey(s.entries[middle]), key) == .lt) low = middle + 1 else high = middle;
    }
    return low;
}
fn canonicalOrigin(output: []u8, input: []const u8) ![]const u8 {
    if (!(std.ascii.startsWithIgnoreCase(input, "https://") or std.ascii.startsWithIgnoreCase(input, "http://"))) return error.InvalidPolicyOrigin;
    return schemes.canonicalOrigin(output, input, &.{});
}
fn validateRule(rule: Rule, limits: Limits) !void {
    if (rule.issued_at < 0 or rule.expires_at <= rule.issued_at or @as(u64, @intCast(rule.expires_at - rule.issued_at)) > limits.max_ttl_seconds) return error.InvalidPolicyExpiry;
    if (rule.action == .download) {
        const constraints = rule.action.download.constraints;
        if (constraints.max_known_bytes == 0 or constraints.max_received_bytes == 0) return error.InvalidDownloadLimits;
        if (rule.action.download.decision != .allow and constraints.folder_key != null) return error.InvalidFolderPolicy;
    }
}
fn validAt(entry: Entry, now: i64) bool {
    return now >= entry.rule.issued_at and now < entry.rule.expires_at;
}
fn checkOwner(s: *const State) !void {
    if (std.Thread.getCurrentId() != s.owner) return error.WrongThread;
}
fn checkMain(s: *const State) !void {
    try checkOwner(s);
    if (!s.adopted or s.owner != s.main_thread) return error.NotAdopted;
}
fn allocate(allocator: std.mem.Allocator, main_thread: std.Thread.Id, scope: Scope, limits: Limits, adopted: bool) !*Store {
    try limits.validate();
    const s = try allocator.create(State);
    errdefer allocator.destroy(s);
    s.* = .{ .allocator = allocator, .main_thread = main_thread, .owner = std.Thread.getCurrentId(), .adopted = adopted, .identity = try identity(), .scope = scope, .limits = limits };
    return @ptrCast(s);
}
/// Stable owning object. Mutation/lookup/snapshot are main-thread-only. A worker
/// decode/load candidate is exclusive until adopt; failed post closes it there.
pub const Store = opaque {
    pub fn init(allocator: std.mem.Allocator, main_thread: std.Thread.Id, scope: Scope, limits: Limits) !*Store {
        if (std.Thread.getCurrentId() != main_thread) return error.WrongThread;
        return allocate(allocator, main_thread, scope, limits, true);
    }
    pub fn adopt(self: *Store) !void {
        const s = state(self);
        if (std.Thread.getCurrentId() != s.main_thread) return error.WrongThread;
        if (s.adopted) return error.AlreadyAdopted;
        s.owner = s.main_thread;
        s.adopted = true;
    }
    pub fn close(self: *Store) !void {
        const s = state(self);
        try checkOwner(s);
        const allocator = s.allocator;
        if (s.storage) |storage| allocator.free(storage);
        allocator.destroy(s);
    }
    pub fn stats(self: *const Store) !Stats {
        const s = state(self);
        try checkOwner(s);
        return .{ .rules = s.entries.len, .owned_bytes = @sizeOf(State) + if (s.storage) |storage| storage.len else @as(usize, 0), .mutation_peak_bytes = s.mutation_peak_bytes, .revision = s.revision };
    }
    pub fn put(self: *Store, rule: Rule) !void {
        const s = state(self);
        try checkMain(s);
        try validateRule(rule, s.limits);
        var canonical: [schemes.origin_limit]u8 = undefined;
        var value = rule;
        value.origin = try canonicalOrigin(&canonical, rule.origin);
        const at = lowerBound(s, .{ .origin = value.origin, .subject = value.action.subject() }, null);
        const replace = at < s.entries.len and compare(entryKey(s.entries[at]), .{ .origin = value.origin, .subject = value.action.subject() }) == .eq;
        try publish(s, at, replace, .{ .rule = value, .revision = try nextRevision(s) });
    }
    pub fn revoke(self: *Store, key: Key) !bool {
        const s = state(self);
        try checkMain(s);
        var canonical: [schemes.origin_limit]u8 = undefined;
        const value: Key = .{ .origin = try canonicalOrigin(&canonical, key.origin), .subject = key.subject };
        const at = lowerBound(s, value, null);
        if (at == s.entries.len or compare(entryKey(s.entries[at]), value) != .eq) return false;
        _ = try nextRevision(s);
        try publish(s, at, true, null);
        return true;
    }
    pub fn clear(self: *Store) !void {
        const s = state(self);
        try checkMain(s);
        if (s.entries.len == 0) return;
        const revision = try nextRevision(s);
        const old = s.storage;
        s.storage = null;
        s.entries = &.{};
        s.revision = revision;
        if (old) |storage| s.allocator.free(storage);
    }
    pub fn lookup(self: *const Store, key: Key, now: i64) !?DecisionLease {
        return self.lookupWithStats(key, now, null);
    }
    pub fn lookupWithStats(self: *const Store, key: Key, now: i64, metrics: ?*LookupStats) !?DecisionLease {
        const s = state(self);
        try checkMain(s);
        var canonical: [schemes.origin_limit]u8 = undefined;
        const value: Key = .{ .origin = try canonicalOrigin(&canonical, key.origin), .subject = key.subject };
        const at = lowerBound(s, value, metrics);
        if (at == s.entries.len or compare(entryKey(s.entries[at]), value) != .eq or !validAt(s.entries[at], now)) return null;
        const entry = s.entries[at];
        var lease: DecisionLease = .{ .store_identity = s.identity, .scope = s.scope, .origin_length = @intCast(entry.rule.origin.len), .rule_revision = entry.revision, .issued_at = entry.rule.issued_at, .expires_at = entry.rule.expires_at, .action = entry.rule.action };
        @memcpy(lease.origin[0..entry.rule.origin.len], entry.rule.origin);
        return lease;
    }
    pub fn validateLease(self: *const Store, lease: *const DecisionLease, now: i64) !bool {
        const s = state(self);
        try checkMain(s);
        if (lease.store_identity != s.identity or !sameScope(lease.scope, s.scope) or lease.origin_length > schemes.origin_limit) return false;
        const at = lowerBound(s, lease.key(), null);
        if (at == s.entries.len) return false;
        const entry = s.entries[at];
        return compare(entryKey(entry), lease.key()) == .eq and entry.revision == lease.rule_revision and entry.rule.issued_at == lease.issued_at and entry.rule.expires_at == lease.expires_at and std.meta.eql(entry.rule.action, lease.action) and validAt(entry, now);
    }
    pub fn snapshot(self: *const Store, allocator: std.mem.Allocator) !Snapshot {
        const s = state(self);
        try checkMain(s);
        var size: usize = header_size;
        for (s.entries) |entry| size = try std.math.add(usize, size, record_size + entry.rule.origin.len);
        if (size > s.limits.file_bytes) return error.PolicyFileTooLarge;
        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);
        @memset(bytes, 0);
        @memcpy(bytes[0..8], magic);
        var at: usize = 8;
        write(u16, bytes, &at, 1);
        write(u16, bytes, &at, 0);
        @memcpy(bytes[12..28], &s.scope.namespace);
        at = 28;
        write(u64, bytes, &at, s.scope.policy_epoch);
        write(u64, bytes, &at, s.revision);
        write(u32, bytes, &at, @intCast(s.entries.len));
        write(u32, bytes, &at, @intCast(size - header_size));
        at = header_size;
        for (s.entries) |entry| {
            const action = entry.rule.action;
            const constraints = if (action == .download) action.download.constraints else DownloadConstraints{ .max_known_bytes = 0, .max_received_bytes = 0 };
            write(u8, bytes, &at, code(action.subject()));
            write(u8, bytes, &at, @backingInt(action.decision()));
            write(u16, bytes, &at, if (action == .download) @as(u16, @intFromBool(constraints.allow_unknown_length)) | (@as(u16, @intFromBool(constraints.folder_key != null)) << 1) else 0);
            write(u16, bytes, &at, @intCast(entry.rule.origin.len));
            write(u16, bytes, &at, 0);
            write(u64, bytes, &at, entry.revision);
            write(i64, bytes, &at, entry.rule.issued_at);
            write(i64, bytes, &at, entry.rule.expires_at);
            write(u64, bytes, &at, constraints.max_known_bytes);
            write(u64, bytes, &at, constraints.max_received_bytes);
            write(u64, bytes, &at, constraints.folder_key orelse 0);
            @memcpy(bytes[at..][0..entry.rule.origin.len], entry.rule.origin);
            at += entry.rule.origin.len;
        }
        std.debug.assert(at == size);
        at = 52;
        write(u32, bytes, &at, checksum(bytes));
        return .{ .allocator = allocator, .bytes = bytes };
    }
};
fn nextRevision(s: *const State) !u64 {
    if (s.revision == std.math.maxInt(u64)) return error.PolicyRevisionExhausted;
    return s.revision + 1;
}
fn publish(s: *State, at: usize, replace: bool, replacement: ?Entry) !void {
    const revision = try nextRevision(s);
    const count = s.entries.len - @intFromBool(replace) + @intFromBool(replacement != null);
    if (count > s.limits.rules) return error.Full;
    var characters: usize = if (replacement) |entry| entry.rule.origin.len else 0;
    for (s.entries, 0..) |entry, i| if (!replace or i != at) {
        characters += entry.rule.origin.len;
    };
    const bytes = count * @sizeOf(Entry) + characters;
    if (bytes > s.limits.owned_bytes - @sizeOf(State)) return error.PolicyCapacityExceeded;
    const storage = if (count != 0) try s.allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(Entry)), bytes) else null;
    errdefer if (storage) |owned| s.allocator.free(owned);
    const entries: []Entry = if (storage) |owned| std.mem.bytesAsSlice(Entry, owned[0 .. count * @sizeOf(Entry)]) else &.{};
    var cursor = count * @sizeOf(Entry);
    var written: usize = 0;
    for (0..s.entries.len + 1) |i| {
        if (i == at) if (replacement) |entry| {
            copyEntry(entries, storage.?, &cursor, &written, entry);
        };
        if (i < s.entries.len and (!replace or i != at)) copyEntry(entries, storage.?, &cursor, &written, s.entries[i]);
    }
    std.debug.assert(written == count and cursor == bytes);
    const old = s.storage;
    s.mutation_peak_bytes = @max(s.mutation_peak_bytes, @sizeOf(State) + bytes + if (old) |owned| owned.len else @as(usize, 0));
    s.storage = storage;
    s.entries = entries;
    s.revision = revision;
    if (old) |owned| s.allocator.free(owned);
}
fn copyEntry(entries: []Entry, storage: []u8, cursor: *usize, written: *usize, input: Entry) void {
    const origin = storage[cursor.*..][0..input.rule.origin.len];
    @memcpy(origin, input.rule.origin);
    cursor.* += origin.len;
    entries[written.*] = input;
    entries[written.*].rule.origin = origin;
    written.* += 1;
}
const magic = "ZIGPOL01";
const header_size = 56;
const record_size = 56;
fn checksum(bytes: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(bytes[0..52]);
    crc.update(bytes[header_size..]);
    return crc.final();
}
fn write(comptime T: type, bytes: []u8, at: *usize, value: T) void {
    std.mem.writeInt(T, bytes[at.*..][0..@sizeOf(T)], value, .little);
    at.* += @sizeOf(T);
}
fn read(comptime T: type, bytes: []const u8, at: *usize) !T {
    if (@sizeOf(T) > bytes.len -| at.*) return error.InvalidPolicyFile;
    const value = std.mem.readInt(T, bytes[at.*..][0..@sizeOf(T)], .little);
    at.* += @sizeOf(T);
    return value;
}

/// Immutable owning bytes. Transfer once; deinit is allowed on a worker after a
/// failed post. Encoding is explicit on Store's owner, never implicit in draw.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    bytes: ?[]const u8,
    pub fn deinit(self: *Snapshot) void {
        if (self.bytes) |bytes| self.allocator.free(bytes);
        self.bytes = null;
    }
    pub fn save(self: *const Snapshot, main_thread: std.Thread.Id, absolute_path: []const u8, options: SaveOptions) !void {
        if (options.failure) |failure| failure.* = .{};
        saveFile(self, main_thread, absolute_path, options) catch |err| {
            if (options.failure) |failure| failure.primary_error = err;
            return err;
        };
        if (options.failure) |failure| failure.committed = true;
    }
};

pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
    pub fn cancel(self: *Cancellation) void {
        self.requested.store(true, .release);
    }
    pub fn check(self: *const Cancellation) !void {
        if (self.requested.load(.acquire)) return error.Cancelled;
    }
};
pub const SaveFailure = struct {
    primary_error: ?anyerror = null,
    cleanup_error: ?anyerror = null,
    temporary_name: [64]u8 = undefined,
    temporary_length: u8 = 0,
    committed: bool = false,
};
pub const SaveOptions = struct { cancellation: ?*const Cancellation = null, failure: ?*SaveFailure = null };
fn checkCancellation(cancellation: ?*const Cancellation) !void {
    if (cancellation) |value| try value.check();
}
fn saveFile(snapshot: *const Snapshot, main_thread: std.Thread.Id, absolute_path: []const u8, options: SaveOptions) !void {
    if (std.Thread.getCurrentId() == main_thread) return error.UiThreadForbidden;
    try checkCancellation(options.cancellation);
    const bytes = snapshot.bytes orelse return error.SnapshotConsumed;
    if (bytes.len < header_size or bytes.len > 1024 * 1024) return error.InvalidPolicyFile;
    // Reuse the worker path/name contract, explicitly allowing replacement of
    // an existing ordinary policy file. This metadata does not lock the path.
    var destination = try downloads.Destination.prepare(snapshot.allocator, main_thread, absolute_path, .{ .accept_overwrite = true });
    defer destination.deinit();
    const parent = std.fs.path.dirname(destination.path.?) orelse return error.AbsoluteOutputPathRequired;
    const name = std.fs.path.basename(destination.path.?);
    var directory = try std.Io.Dir.openDirAbsolute(zio.io(), parent, .{});
    defer directory.close(zio.io());
    var random: [16]u8 = undefined;
    zio.random.bytes(&random);
    const encoded = std.fmt.bytesToHex(random, .lower);
    var temporary_storage: [64]u8 = undefined;
    const temporary_name = try std.fmt.bufPrint(&temporary_storage, ".ziggurat-policy-{s}.tmp", .{encoded});
    try checkCancellation(options.cancellation);
    const file = try directory.createFile(zio.io(), temporary_name, .{ .exclusive = true });
    errdefer directory.deleteFile(zio.io(), temporary_name) catch |err| {
        if (options.failure) |failure| {
            failure.cleanup_error = err;
            @memcpy(failure.temporary_name[0..temporary_name.len], temporary_name);
            failure.temporary_length = @intCast(temporary_name.len);
        }
    };
    var opened = true;
    defer if (opened) file.close(zio.io());
    var at: usize = 0;
    while (at < bytes.len) {
        try checkCancellation(options.cancellation);
        const end = @min(at + 64 * 1024, bytes.len);
        try file.writeStreamingAll(zio.io(), bytes[at..end]);
        at = end;
    }
    try checkCancellation(options.cancellation);
    try file.sync(zio.io());
    file.close(zio.io());
    opened = false;
    try checkCancellation(options.cancellation);
    // One rename is the commit point. Cancellation after it cannot roll back.
    // The caller serializes writers and supplies a trusted private directory.
    try directory.rename(temporary_name, directory, name, zio.io());
}
pub fn load(allocator: std.mem.Allocator, main_thread: std.Thread.Id, scope: Scope, absolute_path: []const u8, limits: Limits, cancellation: ?*const Cancellation) !*Store {
    if (std.Thread.getCurrentId() == main_thread) return error.UiThreadForbidden;
    try limits.validate();
    try checkCancellation(cancellation);
    var source = try downloads.Destination.prepare(allocator, main_thread, absolute_path, .{ .accept_overwrite = true });
    defer source.deinit();
    const file = try std.Io.Dir.openFileAbsolute(zio.io(), source.path.?, .{});
    defer file.close(zio.io());
    const metadata = try file.stat(zio.io());
    if (metadata.kind != .file) return error.RegularPolicyFileRequired;
    if (metadata.size < header_size or metadata.size > limits.file_bytes) return error.InvalidPolicyFile;
    const bytes = try allocator.alloc(u8, @intCast(metadata.size));
    defer allocator.free(bytes);
    var at: usize = 0;
    while (at < bytes.len) {
        try checkCancellation(cancellation);
        const count = try zio.read(file, bytes[at..@min(at + 64 * 1024, bytes.len)]);
        if (count == 0) return error.PolicyFileChanged;
        at += count;
    }
    var extra: [1]u8 = undefined;
    if (try zio.read(file, &extra) != 0) return error.PolicyFileChanged;
    try checkCancellation(cancellation);
    const candidate = try decode(allocator, main_thread, scope, bytes, limits);
    errdefer candidate.close() catch unreachable;
    try checkCancellation(cancellation);
    return candidate;
}
/// Pure decode is worker-only, creates a new identity and never modifies a live
/// Store. The exclusive result must be adopted on the supplied main thread.
pub fn decode(allocator: std.mem.Allocator, main_thread: std.Thread.Id, scope: Scope, bytes: []const u8, limits: Limits) !*Store {
    if (std.Thread.getCurrentId() == main_thread) return error.UiThreadForbidden;
    try limits.validate();
    if (bytes.len < header_size or bytes.len > limits.file_bytes or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidPolicyFile;
    var at: usize = 8;
    if (try read(u16, bytes, &at) != 1) return error.UnsupportedPolicyVersion;
    if (try read(u16, bytes, &at) != 0) return error.InvalidPolicyFile;
    var stored_scope: Scope = undefined;
    @memcpy(&stored_scope.namespace, bytes[12..28]);
    at = 28;
    stored_scope.policy_epoch = try read(u64, bytes, &at);
    if (!sameScope(scope, stored_scope)) return error.PolicyScopeMismatch;
    const revision = try read(u64, bytes, &at);
    const count = try read(u32, bytes, &at);
    const payload_bytes = try read(u32, bytes, &at);
    const expected_checksum = try read(u32, bytes, &at);
    if (count > limits.rules or payload_bytes != bytes.len - header_size or checksum(bytes) != expected_checksum) return error.InvalidPolicyFile;
    var inputs: [1024]Entry = undefined;
    var characters: usize = 0;
    for (inputs[0..count], 0..) |*entry, i| {
        const kind = try read(u8, bytes, &at);
        const decision = std.enums.fromInt(Decision, try read(u8, bytes, &at)) orelse return error.InvalidPolicyFile;
        const flags = try read(u16, bytes, &at);
        const length = try read(u16, bytes, &at);
        if (try read(u16, bytes, &at) != 0 or flags & ~@as(u16, 3) != 0 or length > schemes.origin_limit) return error.InvalidPolicyFile;
        const rule_revision = try read(u64, bytes, &at);
        const issued_at = try read(i64, bytes, &at);
        const expires_at = try read(i64, bytes, &at);
        const known = try read(u64, bytes, &at);
        const received = try read(u64, bytes, &at);
        const folder = try read(u64, bytes, &at);
        if (length > bytes.len -| at or rule_revision == 0 or rule_revision > revision) return error.InvalidPolicyFile;
        const origin = bytes[at..][0..length];
        at += length;
        var canonical: [schemes.origin_limit]u8 = undefined;
        if (!std.mem.eql(u8, origin, try canonicalOrigin(&canonical, origin))) return error.NonCanonicalPolicyOrigin;
        var action: Action = undefined;
        if (kind == 14) {
            if (flags & 2 == 0 and folder != 0) return error.InvalidPolicyFile;
            action = .{ .download = .{ .decision = decision, .constraints = .{ .max_known_bytes = known, .max_received_bytes = received, .allow_unknown_length = flags & 1 != 0, .folder_key = if (flags & 2 != 0) folder else null } } };
        } else {
            const permission = permissions.Kind.fromNative(kind) orelse return error.InvalidPolicyFile;
            if (flags != 0 or known != 0 or received != 0 or folder != 0) return error.InvalidPolicyFile;
            action = .{ .permission = .{ .kind = permission, .decision = decision } };
        }
        entry.* = .{ .rule = .{ .origin = origin, .issued_at = issued_at, .expires_at = expires_at, .action = action }, .revision = rule_revision };
        try validateRule(entry.rule, limits);
        if (i > 0 and compare(entryKey(inputs[i - 1]), entryKey(entry.*)) != .lt) return error.DuplicateOrUnsortedPolicy;
        characters += origin.len;
    }
    if (at != bytes.len) return error.InvalidPolicyFile;
    const storage_bytes = count * @sizeOf(Entry) + characters;
    if (storage_bytes > limits.owned_bytes - @sizeOf(State)) return error.PolicyCapacityExceeded;
    const store = try allocate(allocator, main_thread, scope, limits, false);
    errdefer store.close() catch unreachable;
    const s = state(store);
    s.revision = revision;
    if (count != 0) {
        s.storage = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(Entry)), storage_bytes);
        s.entries = std.mem.bytesAsSlice(Entry, s.storage.?[0 .. count * @sizeOf(Entry)]);
        var cursor: usize = count * @sizeOf(Entry);
        var written: usize = 0;
        for (inputs[0..count]) |entry| copyEntry(s.entries, s.storage.?, &cursor, &written, entry);
    }
    s.mutation_peak_bytes = @sizeOf(State) + storage_bytes;
    return store;
}

const test_scope: Scope = .{ .namespace = @as([16]u8, @splat(0x42)), .policy_epoch = 3 };
const test_rule: Rule = .{ .origin = "https://permission.example", .issued_at = 100, .expires_at = 1000, .action = .{ .permission = .{ .kind = .notifications, .decision = .allow } } };
const test_key: Key = .{ .origin = test_rule.origin, .subject = .{ .permission = .notifications } };
const DecodeProbe = struct {
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    scope: Scope = test_scope,
    bytes: []const u8,
    limits: Limits = .{},
    candidate: ?*Store = null,
    err: ?anyerror = null,
    fn run(self: *@This()) void {
        self.candidate = decode(self.allocator, self.main_thread, self.scope, self.bytes, self.limits) catch |err| {
            self.err = err;
            return;
        };
    }
};
fn decodeOnWorker(allocator: std.mem.Allocator, bytes: []const u8, scope: Scope, limits: Limits) !*Store {
    var probe: DecodeProbe = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .scope = scope, .bytes = bytes, .limits = limits };
    const thread = try std.Thread.spawn(.{}, DecodeProbe.run, .{&probe});
    thread.join();
    if (probe.err) |err| return err;
    const candidate = probe.candidate.?;
    try candidate.adopt();
    return candidate;
}
test "policy leases bind owner identity exact key revision scope and validity" {
    const store = try Store.init(std.testing.allocator, std.Thread.getCurrentId(), test_scope, .{});
    defer store.close() catch unreachable;
    var rule = test_rule;
    rule.origin = "HTTPS://PERMISSION.EXAMPLE:443/";
    try store.put(rule);
    var lease = (try store.lookup(test_key, 101)).?;
    try std.testing.expect(try store.validateLease(&lease, 101));
    var altered = lease;
    altered.action.permission.decision = .deny;
    try std.testing.expect(!try store.validateLease(&altered, 101));
    altered = lease;
    altered.action.permission.kind = .camera;
    try std.testing.expect(!try store.validateLease(&altered, 101));
    altered = lease;
    altered.rule_revision += 1;
    try std.testing.expect(!try store.validateLease(&altered, 101));
    try std.testing.expect(!try store.validateLease(&lease, 99));
    try std.testing.expect(!try store.validateLease(&lease, 1000));
    try std.testing.expect((try store.lookup(test_key, 99)) == null and (try store.lookup(test_key, 1000)) == null);
    lease.scope.policy_epoch += 1;
    try std.testing.expect(!try store.validateLease(&lease, 101));
    lease.scope = test_scope;
    try store.put(.{ .origin = "https://other.example", .issued_at = 100, .expires_at = 1000, .action = .{ .permission = .{ .kind = .camera, .decision = .deny } } });
    try std.testing.expect(try store.validateLease(&lease, 101)); // Unrelated keys need not revoke it.
    var changed = test_rule;
    changed.action.permission.decision = .deny;
    try store.put(changed);
    try std.testing.expect(!try store.validateLease(&lease, 101));
    lease = (try store.lookup(test_key, 101)).?;
    try std.testing.expect(try store.revoke(test_key));
    try std.testing.expect(!try store.validateLease(&lease, 101));
    try std.testing.expect(!try store.revoke(test_key));
    try store.clear();
    try std.testing.expectEqual(@as(usize, 0), (try store.stats()).rules);
    const other = try Store.init(std.testing.allocator, std.Thread.getCurrentId(), test_scope, .{});
    defer other.close() catch unreachable;
    try other.put(changed);
    try std.testing.expect(!try other.validateLease(&lease, 101));
    var invalid = test_rule;
    invalid.issued_at = -1;
    try std.testing.expectError(error.InvalidPolicyExpiry, other.put(invalid));
    invalid = test_rule;
    invalid.expires_at = invalid.issued_at;
    try std.testing.expectError(error.InvalidPolicyExpiry, other.put(invalid));
    invalid.expires_at = invalid.issued_at + 30 * 24 * 60 * 60 + 1;
    try std.testing.expectError(error.InvalidPolicyExpiry, other.put(invalid));
}
test "policy mutation snapshot and decoded candidate roll back every allocation" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const store = try Store.init(allocator, std.Thread.getCurrentId(), test_scope, .{});
            defer store.close() catch unreachable;
            try store.put(test_rule);
            const lease = (try store.lookup(test_key, 101)).?;
            const second: Rule = .{ .origin = "http://127.0.0.1:1234", .issued_at = 100, .expires_at = 1000, .action = .{ .download = .{ .decision = .allow, .constraints = .{ .max_known_bytes = 1024, .max_received_bytes = 2048, .folder_key = 7 } } } };
            store.put(second) catch |err| {
                try std.testing.expect((try store.stats()).rules == 1 and try store.validateLease(&lease, 101));
                return err;
            };
            var snapshot = try store.snapshot(allocator);
            defer snapshot.deinit();
            const candidate = try decodeOnWorker(allocator, snapshot.bytes.?, test_scope, .{});
            defer candidate.close() catch unreachable;
            try std.testing.expectEqual(@as(usize, 2), (try candidate.stats()).rules);
            try std.testing.expect(!try candidate.validateLease(&lease, 101));
            const download = (try candidate.lookup(.{ .origin = second.origin, .subject = .download }, 101)).?;
            try std.testing.expectEqual(@as(?u64, 7), download.action.download.constraints.folder_key);
            const narrowed = download.action.download.constraints.intersect(.{ .max_known_bytes = 100, .max_received_bytes = 200, .allow_unknown_length = false });
            try std.testing.expect(narrowed.max_known_bytes == 100 and narrowed.max_received_bytes == 200 and !narrowed.allow_unknown_length);
            _ = try store.revoke(test_key);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}
test "policy encoding rejects truncation corruption scope versions duplicate and noncanonical data" {
    const store = try Store.init(std.testing.allocator, std.Thread.getCurrentId(), test_scope, .{});
    defer store.close() catch unreachable;
    try store.put(test_rule);
    var snapshot = try store.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    const original = snapshot.bytes.?;
    for (0..original.len) |length| {
        const candidate = decodeOnWorker(std.testing.allocator, original[0..length], test_scope, .{});
        if (candidate) |value| {
            value.close() catch unreachable;
            return error.AcceptedTruncatedPolicy;
        } else |_| {}
    }
    var wrong_scope = test_scope;
    wrong_scope.namespace[0] ^= 1;
    try std.testing.expectError(error.PolicyScopeMismatch, decodeOnWorker(std.testing.allocator, original, wrong_scope, .{}));
    const copy = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(copy);
    copy[8] = 2;
    try std.testing.expectError(error.UnsupportedPolicyVersion, decodeOnWorker(std.testing.allocator, copy, test_scope, .{}));
    @memcpy(copy, original);
    copy[original.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidPolicyFile, decodeOnWorker(std.testing.allocator, copy, test_scope, .{}));
    @memcpy(copy, original);
    copy[header_size + record_size + 8] = 'P';
    var at: usize = 52;
    write(u32, copy, &at, checksum(copy));
    try std.testing.expectError(error.NonCanonicalPolicyOrigin, decodeOnWorker(std.testing.allocator, copy, test_scope, .{}));
    @memcpy(copy, original);
    copy[header_size] = 255;
    at = 52;
    write(u32, copy, &at, checksum(copy));
    try std.testing.expectError(error.InvalidPolicyFile, decodeOnWorker(std.testing.allocator, copy, test_scope, .{}));
    const record = original[header_size..];
    const duplicate = try std.testing.allocator.alloc(u8, header_size + record.len * 2);
    defer std.testing.allocator.free(duplicate);
    @memcpy(duplicate[0..header_size], original[0..header_size]);
    @memcpy(duplicate[header_size..][0..record.len], record);
    @memcpy(duplicate[header_size + record.len ..], record);
    at = 44;
    write(u32, duplicate, &at, 2);
    write(u32, duplicate, &at, @intCast(record.len * 2));
    write(u32, duplicate, &at, checksum(duplicate));
    try std.testing.expectError(error.DuplicateOrUnsortedPolicy, decodeOnWorker(std.testing.allocator, duplicate, test_scope, .{}));
}
test "policy limits revision exhaustion and thousand-rule binary lookup are explicit" {
    const main_thread = std.Thread.getCurrentId();
    const store = try Store.init(std.testing.allocator, main_thread, test_scope, .{ .rules = 1024, .owned_bytes = 1024 * 1024, .file_bytes = 1024 * 1024 });
    defer store.close() catch unreachable;
    for (0..1024) |i| {
        var buffer: [128]u8 = undefined;
        var rule = test_rule;
        rule.origin = try std.fmt.bufPrint(&buffer, "https://host{d}.example", .{i});
        try store.put(rule);
    }
    var metrics: LookupStats = .{};
    const lease = (try store.lookupWithStats(.{ .origin = "https://host777.example", .subject = .{ .permission = .notifications } }, 101, &metrics)).?;
    try std.testing.expect(metrics.comparisons <= 11 and try store.validateLease(&lease, 101));
    try std.testing.expectError(error.Full, store.put(test_rule));
    state(store).revision = std.math.maxInt(u64);
    try std.testing.expectError(error.PolicyRevisionExhausted, store.put(test_rule));
    try std.testing.expectError(error.PolicyRevisionExhausted, store.revoke(lease.key()));
    try std.testing.expectError(error.PolicyRevisionExhausted, store.clear());
    try std.testing.expectEqual(@as(usize, 1024), (try store.stats()).rules);
    try std.testing.expectError(error.UiThreadForbidden, decode(std.testing.failing_allocator, main_thread, test_scope, "", .{}));
}

fn expectNoTemporaryFiles(directory: std.Io.Dir) !void {
    var iterable = try directory.openDir(zio.io(), ".", .{ .iterate = true });
    defer iterable.close(zio.io());
    var iterator = iterable.iterate();
    while (try iterator.next(zio.io())) |entry| if (std.mem.startsWith(u8, entry.name, ".ziggurat-policy-")) return error.TemporaryPolicyLeaked;
}
test "worker save replaces a private file and failed rename or cancellation preserves it" {
    const main_thread = std.Thread.getCurrentId();
    const store = try Store.init(std.testing.allocator, main_thread, test_scope, .{});
    defer store.close() catch unreachable;
    try store.put(test_rule);
    var first = try store.snapshot(std.testing.allocator);
    defer first.deinit();
    var changed = test_rule;
    changed.action.permission.decision = .deny;
    try store.put(changed);
    var second = try store.snapshot(std.testing.allocator);
    defer second.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const Probe = struct {
        main_thread: std.Thread.Id,
        temporary: *std.testing.TmpDir,
        live: *Store,
        first: *const Snapshot,
        second: *const Snapshot,
        candidate: ?*Store = null,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            self.work() catch |err| {
                self.err = err;
            };
        }
        fn work(self: *@This()) !void {
            try std.testing.expectError(error.WrongThread, self.live.lookup(test_key, 101));
            const parent = try zio.realPathAlloc(self.temporary.dir, ".", std.testing.allocator);
            defer std.testing.allocator.free(parent);
            const path = try std.fs.path.join(std.testing.allocator, &.{ parent, "策略.bin" });
            defer std.testing.allocator.free(path);
            try self.first.save(self.main_thread, path, .{});
            try self.second.save(self.main_thread, path, .{});
            var cancellation: Cancellation = .{};
            cancellation.cancel();
            try std.testing.expectError(error.Cancelled, self.first.save(self.main_thread, path, .{ .cancellation = &cancellation }));
            try std.testing.expectError(error.Cancelled, load(std.testing.failing_allocator, self.main_thread, test_scope, path, .{}, &cancellation));
            try std.testing.expectError(error.UiThreadForbidden, self.first.save(std.Thread.getCurrentId(), path, .{}));
            if (@import("builtin").os.tag == .windows) {
                const w = @import("ziggurat_c_win32");
                const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
                defer std.testing.allocator.free(wide);
                const handle = w.CreateFileW(wide.ptr, w.GENERIC_READ, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE, null, w.OPEN_EXISTING, 0, null);
                if (handle == w.INVALID_HANDLE_VALUE or handle == null) return error.CannotLockPrivatePolicy;
                defer _ = w.CloseHandle(handle);
                var failure: SaveFailure = .{};
                const result = self.first.save(self.main_thread, path, .{ .failure = &failure });
                if (result) |_| return error.RenameIgnoredNativeLock else |_| {}
                try std.testing.expect(failure.primary_error != null and failure.cleanup_error == null and !failure.committed);
            }
            const preserved = try self.temporary.dir.readFileAlloc(zio.io(), "策略.bin", std.testing.allocator, .limited(1024 * 1024));
            defer std.testing.allocator.free(preserved);
            try std.testing.expectEqualSlices(u8, self.second.bytes.?, preserved);
            try expectNoTemporaryFiles(self.temporary.dir);
            self.candidate = try load(std.testing.allocator, self.main_thread, test_scope, path, .{}, null);
            errdefer {
                self.candidate.?.close() catch unreachable;
                self.candidate = null;
            }
            try std.testing.expectError(error.NotAdopted, self.candidate.?.lookup(test_key, 101));
        }
    };
    var probe: Probe = .{ .main_thread = main_thread, .temporary = &temporary, .live = store, .first = &first, .second = &second };
    const worker = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    worker.join();
    if (probe.err) |err| return err;
    const candidate = probe.candidate.?;
    try candidate.adopt();
    defer candidate.close() catch unreachable;
    const lease = (try candidate.lookup(test_key, 101)).?;
    try std.testing.expectEqual(Decision.deny, lease.action.decision());
    try std.testing.expectError(error.AlreadyAdopted, candidate.adopt());
    try std.testing.expectError(error.UiThreadForbidden, load(std.testing.failing_allocator, main_thread, test_scope, "unused", .{}, null));
}
test "worker persistence allocation failures retain old files and release candidates" {
    const store = try Store.init(std.testing.allocator, std.Thread.getCurrentId(), test_scope, .{});
    defer store.close() catch unreachable;
    try store.put(test_rule);
    var snapshot = try store.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const Probe = struct {
        allocator: std.mem.Allocator,
        main_thread: std.Thread.Id,
        temporary: *std.testing.TmpDir,
        snapshot: *const Snapshot,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            self.work() catch |err| {
                self.err = err;
            };
        }
        fn work(self: *@This()) !void {
            const parent = try zio.realPathAlloc(self.temporary.dir, ".", std.testing.allocator);
            defer std.testing.allocator.free(parent);
            const path = try std.fs.path.join(std.testing.allocator, &.{ parent, "policy.bin" });
            defer std.testing.allocator.free(path);
            try self.temporary.dir.writeFile(zio.io(), .{ .sub_path = "policy.bin", .data = "previous-private-file" });
            var owned: Snapshot = .{ .allocator = self.allocator, .bytes = try self.allocator.dupe(u8, self.snapshot.bytes.?) };
            defer owned.deinit();
            owned.save(self.main_thread, path, .{}) catch |err| {
                const previous = try self.temporary.dir.readFileAlloc(zio.io(), "policy.bin", std.testing.allocator, .limited(1024 * 1024));
                defer std.testing.allocator.free(previous);
                try std.testing.expectEqualStrings("previous-private-file", previous);
                try expectNoTemporaryFiles(self.temporary.dir);
                return err;
            };
            const candidate = load(self.allocator, self.main_thread, test_scope, path, .{}, null) catch |err| {
                try expectNoTemporaryFiles(self.temporary.dir);
                return err;
            };
            defer candidate.close() catch unreachable;
            try expectNoTemporaryFiles(self.temporary.dir);
        }
        fn allocationCase(allocator: std.mem.Allocator, test_directory: *std.testing.TmpDir, test_snapshot: *const Snapshot) !void {
            var probe: @This() = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .temporary = test_directory, .snapshot = test_snapshot };
            const thread = try std.Thread.spawn(.{}, run, .{&probe});
            thread.join();
            if (probe.err) |err| return err;
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.allocationCase, .{ &temporary, &snapshot });
}
