const std = @import("std");
const update = @import("root.zig");
const delta = @import("delta.zig");

/// A feed lists individually signed full and delta manifests. The feed itself
/// is an unsigned index: every entry a client acts on is verified on its own,
/// and the policy's version floor rejects replayed older entries. A feed can
/// still withhold newer releases; it cannot make a client accept a forged one.
pub const Wire = struct {
    format: u16,
    identity: []const u8,
    releases: []const update.Wire,
    deltas: []const delta.Wire = &.{},
    /// Release notes by version, shown before installing. Unsigned, like the
    /// rest of the index: display text only, never acted on.
    notes: []const Note = &.{},
    /// Versions published as prereleases, such as a beta: only clients
    /// that offer prereleases (`Channel.prereleases`) take them. Unsigned,
    /// like the rest of the index, which can always withhold a release.
    prereleases: []const update.Version = &.{},
};
pub const Note = struct { version: update.Version, text: []const u8 };
pub const max_notes_bytes = 64 * 1024;

pub const max_feed_bytes = 1024 * 1024;

/// The installed release, when its authenticated archive is retained so a
/// delta can rebuild the next archive from it.
pub const Installed = struct { sha256: [32]u8 };

pub const Available = struct {
    full: update.Verified,
    delta: ?delta.Verified,
    pub fn deinit(self: Available) void {
        self.full.deinit();
        if (self.delta) |value| value.deinit();
    }
};

/// Which releases a check takes.
pub const Channel = struct {
    /// Prereleases too, for users who chose a beta. A client that turns it
    /// off installs no older version: it updates again once a release is
    /// newer than the prerelease it runs.
    prereleases: bool = false,
};

pub const Check = union(enum) {
    current,
    available: Available,
    pub fn deinit(self: Check) void {
        switch (self) {
            .current => {},
            .available => |value| value.deinit(),
        }
    }
};

/// Select the newest full release for the policy's identity and target and,
/// when `installed` is given, a delta from the installed archive to exactly
/// that release. Entries for other targets are ignored; an entry for this
/// target that fails verification fails the whole check rather than silently
/// choosing an older release. Returned manifests own their storage.
pub fn check(allocator: std.mem.Allocator, bytes: []const u8, policy: update.Policy, installed: ?Installed) !Check {
    return checkChannel(allocator, bytes, policy, installed, .{});
}

/// `check` on a channel: without `prereleases`, the versions the feed lists
/// as prereleases are passed over.
pub fn checkChannel(allocator: std.mem.Allocator, bytes: []const u8, policy: update.Policy, installed: ?Installed, channel: Channel) !Check {
    if (bytes.len > max_feed_bytes) return error.FeedTooLarge;
    const parsed = std.json.parseFromSlice(Wire, allocator, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidFeed;
    };
    defer parsed.deinit();
    const feed = parsed.value;
    if (feed.format != 1) return error.UnsupportedFormat;
    if (!std.mem.eql(u8, feed.identity, policy.identity)) return error.WrongIdentity;
    var best: ?usize = null;
    for (feed.releases, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.target, policy.target)) continue;
        if (entry.version.order(policy.current_version) != .gt) continue;
        if (!channel.prereleases and listed(feed.prereleases, entry.version)) continue;
        if (best) |previous| switch (entry.version.order(feed.releases[previous].version)) {
            .gt => {},
            .eq => return error.DuplicateRelease,
            .lt => continue,
        };
        best = index;
    }
    const chosen = best orelse return .current;
    const full = try reverify(update.Wire, update.Verified, allocator, feed.releases[chosen], policy, {});
    errdefer full.deinit();
    var selected: ?delta.Verified = null;
    if (installed) |source| for (feed.deltas) |entry| {
        if (!std.mem.eql(u8, entry.target, policy.target)) continue;
        if (entry.from.order(policy.current_version) != .eq or entry.to.order(full.manifest.version) != .eq) continue;
        // A delta from another build of the installed version is not an error.
        var source_digest: [32]u8 = undefined;
        if (entry.source_sha256.len != 64) return error.InvalidEncoding;
        _ = std.fmt.hexToBytes(&source_digest, entry.source_sha256) catch return error.InvalidEncoding;
        if (!std.mem.eql(u8, &source_digest, &source.sha256)) continue;
        const candidate = try reverify(delta.Wire, delta.Verified, allocator, entry, policy, source.sha256);
        if (candidate.manifest.result_bytes != full.manifest.bytes or !std.crypto.timing_safe.eql([32]u8, candidate.manifest.result_sha256, full.manifest.sha256)) {
            candidate.deinit();
            return error.DeltaResultMismatch;
        }
        if (selected) |previous| {
            // Prefer the smaller of two valid patches for the same pair.
            if (previous.manifest.bytes <= candidate.manifest.bytes) {
                candidate.deinit();
                continue;
            }
            previous.deinit();
        }
        selected = candidate;
    };
    return .{ .available = .{ .full = full, .delta = selected } };
}

fn listed(versions: []const update.Version, version: update.Version) bool {
    for (versions) |candidate| if (candidate.order(version) == .eq) return true;
    return false;
}

fn reverify(comptime W: type, comptime V: type, allocator: std.mem.Allocator, entry: W, policy: update.Policy, extra: anytype) !V {
    // Round-trip the entry so the verified manifest owns independent storage.
    const json = try std.json.Stringify.valueAlloc(allocator, entry, .{ .emit_null_optional_fields = false });
    defer allocator.free(json);
    if (W == update.Wire) return update.parseAndVerify(allocator, json, policy);
    return delta.parseAndVerify(allocator, json, policy, extra);
}

/// The notes the feed lists for `version`, or an empty string. Caller frees.
pub fn notesFor(allocator: std.mem.Allocator, bytes: []const u8, version: update.Version) ![]u8 {
    if (bytes.len > max_feed_bytes) return error.FeedTooLarge;
    const parsed = std.json.parseFromSlice(Wire, allocator, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidFeed;
    };
    defer parsed.deinit();
    for (parsed.value.notes) |note| {
        if (note.version.order(version) != .eq) continue;
        if (note.text.len > max_notes_bytes or !std.unicode.utf8ValidateSlice(note.text)) return error.InvalidNotes;
        return allocator.dupe(u8, note.text);
    }
    return allocator.dupe(u8, "");
}

/// Build feed JSON from already signed manifest documents. Entries are kept in
/// the given order; each document is parsed strictly but not re-signed.
pub fn build(allocator: std.mem.Allocator, identity: []const u8, releases: []const []const u8, deltas: []const []const u8) ![]u8 {
    return buildWithNotes(allocator, identity, releases, deltas, &.{});
}

/// `build` with release notes by version.
pub fn buildWithNotes(allocator: std.mem.Allocator, identity: []const u8, releases: []const []const u8, deltas: []const []const u8, notes: []const Note) ![]u8 {
    return buildWith(allocator, identity, releases, deltas, .{ .notes = notes });
}

/// What a feed lists besides its manifests.
pub const Extras = struct {
    notes: []const Note = &.{},
    prereleases: []const update.Version = &.{},
};

/// `build` with release notes and prereleases.
pub fn buildWith(allocator: std.mem.Allocator, identity: []const u8, releases: []const []const u8, deltas: []const []const u8, extras: Extras) ![]u8 {
    const notes = extras.notes;
    for (notes) |note| if (note.text.len > max_notes_bytes or !std.unicode.utf8ValidateSlice(note.text)) return error.InvalidNotes;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const full = try scratch.alloc(update.Wire, releases.len);
    for (releases, full) |text, *out| {
        out.* = std.json.parseFromSliceLeaky(update.Wire, scratch, text, .{ .duplicate_field_behavior = .@"error" }) catch return error.InvalidManifest;
        if (!std.mem.eql(u8, out.identity, identity)) return error.WrongIdentity;
    }
    const patches = try scratch.alloc(delta.Wire, deltas.len);
    for (deltas, patches) |text, *out| {
        out.* = std.json.parseFromSliceLeaky(delta.Wire, scratch, text, .{ .duplicate_field_behavior = .@"error" }) catch return error.InvalidManifest;
        if (!std.mem.eql(u8, out.identity, identity)) return error.WrongIdentity;
    }
    return std.json.Stringify.valueAlloc(allocator, Wire{ .format = 1, .identity = identity, .releases = full, .deltas = patches, .notes = notes, .prereleases = extras.prereleases }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
}

test "feed selects the newest verified release and a matching delta" {
    const allocator = std.testing.allocator;
    const key = try update.Ed25519.KeyPair.generateDeterministic(@splat(11));
    const identity = "org.ziggurat.Feed";
    var documents: [4][]u8 = undefined;
    var count: usize = 0;
    defer for (documents[0..count]) |document| allocator.free(document);
    const versions = [_]update.Version{ .{ .major = 1, .minor = 1, .patch = 0 }, .{ .major = 1, .minor = 2, .patch = 0 } };
    for (versions) |version| {
        var manifest: update.Manifest = .{ .identity = identity, .target = "linux-x86_64", .version = version, .url = "https://example.invalid/full.zip", .bytes = 100 + version.minor, .sha256 = @splat(@intCast(version.minor)), .signature = undefined };
        documents[count] = try update.sign(allocator, manifest, key);
        count += 1;
        manifest.target = "windows-x86_64";
        documents[count] = try update.sign(allocator, manifest, key);
        count += 1;
    }
    var patch: delta.Manifest = .{ .identity = identity, .target = "linux-x86_64", .from = .{ .major = 1, .minor = 0, .patch = 0 }, .to = versions[1], .source_bytes = 90, .source_sha256 = @splat(7), .url = "https://example.invalid/1.0-1.2.patch", .bytes = 20, .sha256 = @splat(8), .result_bytes = 102, .result_sha256 = @splat(2), .signature = undefined };
    const patch_json = try delta.sign(allocator, patch, key);
    defer allocator.free(patch_json);
    const json = try build(allocator, identity, documents[0..count], &.{patch_json});
    defer allocator.free(json);
    const policy: update.Policy = .{ .identity = identity, .target = "linux-x86_64", .current_version = .{ .major = 1, .minor = 0, .patch = 0 }, .public_key = key.public_key.toBytes() };

    const result = try check(allocator, json, policy, .{ .sha256 = @splat(7) });
    defer result.deinit();
    try std.testing.expectEqual(versions[1], result.available.full.manifest.version);
    try std.testing.expectEqual(@as(u64, 20), result.available.delta.?.manifest.bytes);
    const no_delta = try check(allocator, json, policy, .{ .sha256 = @splat(6) });
    defer no_delta.deinit();
    try std.testing.expect(no_delta.available.delta == null);
    var newest = policy;
    newest.current_version = versions[1];
    try std.testing.expect((try check(allocator, json, newest, null)) == .current);
    var other = policy;
    other.identity = "org.ziggurat.Other";
    try std.testing.expectError(error.WrongIdentity, check(allocator, json, other, null));

    // Mismatched delta result or tampered entry fails closed.
    patch.result_sha256 = @splat(9);
    const wrong = try delta.sign(allocator, patch, key);
    defer allocator.free(wrong);
    const bad = try build(allocator, identity, documents[0..count], &.{wrong});
    defer allocator.free(bad);
    try std.testing.expectError(error.DeltaResultMismatch, check(allocator, bad, policy, .{ .sha256 = @splat(7) }));
    const tampered = try allocator.dupe(u8, json);
    defer allocator.free(tampered);
    const at = std.mem.indexOf(u8, tampered, "\"bytes\": 102").?;
    tampered[at + 11] = '3';
    try std.testing.expectError(error.InvalidSignature, check(allocator, tampered, policy, null));
}

test "feeds carry release notes by version" {
    const allocator = std.testing.allocator;
    const key = try update.Ed25519.KeyPair.generateDeterministic(@splat(13));
    const identity = "org.ziggurat.Feed";
    const v2: update.Version = .{ .major = 2, .minor = 0, .patch = 0 };
    const full = try update.sign(allocator, .{ .identity = identity, .target = "linux-x86_64", .version = v2, .url = "https://example.invalid/a.zip", .bytes = 5, .sha256 = @splat(3), .signature = undefined }, key);
    defer allocator.free(full);
    const json = try buildWithNotes(allocator, identity, &.{full}, &.{}, &.{.{ .version = v2, .text = "修复了崩溃\n\nFaster start" }});
    defer allocator.free(json);
    const notes = try notesFor(allocator, json, v2);
    defer allocator.free(notes);
    try std.testing.expectEqualStrings("修复了崩溃\n\nFaster start", notes);
    const none = try notesFor(allocator, json, .{ .major = 3, .minor = 0, .patch = 0 });
    defer allocator.free(none);
    try std.testing.expectEqualStrings("", none);
    // The notes do not disturb the signed check.
    const result = try check(allocator, json, .{ .identity = identity, .target = "linux-x86_64", .current_version = .{ .major = 1, .minor = 0, .patch = 0 }, .public_key = key.public_key.toBytes() }, null);
    defer result.deinit();
    try std.testing.expectEqual(v2, result.available.full.manifest.version);
    try std.testing.expectError(error.InvalidNotes, buildWithNotes(allocator, identity, &.{full}, &.{}, &.{.{ .version = v2, .text = "\xff" }}));
}

test "prereleases go only to clients that offer them, and never downgrade" {
    const allocator = std.testing.allocator;
    const key = try update.Ed25519.KeyPair.generateDeterministic(@splat(14));
    const identity = "org.ziggurat.Feed";
    const v2: update.Version = .{ .major = 2, .minor = 0, .patch = 0 };
    const beta: update.Version = .{ .major = 2, .minor = 1, .patch = 0, .revision = 1 };
    const stable = try update.sign(allocator, .{ .identity = identity, .target = "linux-x86_64", .version = v2, .url = "https://example.invalid/a.zip", .bytes = 5, .sha256 = @splat(3), .signature = undefined }, key);
    defer allocator.free(stable);
    const pre = try update.sign(allocator, .{ .identity = identity, .target = "linux-x86_64", .version = beta, .url = "https://example.invalid/b.zip", .bytes = 6, .sha256 = @splat(4), .signature = undefined }, key);
    defer allocator.free(pre);
    const json = try buildWith(allocator, identity, &.{ stable, pre }, &.{}, .{ .prereleases = &.{beta} });
    defer allocator.free(json);
    var policy: update.Policy = .{ .identity = identity, .target = "linux-x86_64", .current_version = .{ .major = 1, .minor = 0, .patch = 0 }, .public_key = key.public_key.toBytes() };
    const plain = try check(allocator, json, policy, null);
    defer plain.deinit();
    try std.testing.expectEqual(v2, plain.available.full.manifest.version);
    const offered = try checkChannel(allocator, json, policy, null, .{ .prereleases = true });
    defer offered.deinit();
    try std.testing.expectEqual(beta, offered.available.full.manifest.version);
    // On the beta with prereleases turned off: nothing older is offered.
    policy.current_version = beta;
    try std.testing.expect((try check(allocator, json, policy, null)) == .current);
}

test "feed check frees all allocations at every failure" {
    const Fixture = struct {
        fn run(allocator: std.mem.Allocator, json: []const u8, policy: update.Policy) !void {
            const result = try check(allocator, json, policy, .{ .sha256 = @splat(7) });
            result.deinit();
        }
    };
    const allocator = std.testing.allocator;
    const key = try update.Ed25519.KeyPair.generateDeterministic(@splat(12));
    const identity = "org.ziggurat.Feed";
    const full = try update.sign(allocator, .{ .identity = identity, .target = "linux-x86_64", .version = .{ .major = 2, .minor = 0, .patch = 0 }, .url = "https://example.invalid/a.zip", .bytes = 5, .sha256 = @splat(3), .signature = undefined }, key);
    defer allocator.free(full);
    const patch = try delta.sign(allocator, .{ .identity = identity, .target = "linux-x86_64", .from = .{ .major = 1, .minor = 0, .patch = 0 }, .to = .{ .major = 2, .minor = 0, .patch = 0 }, .source_bytes = 4, .source_sha256 = @splat(7), .url = "https://example.invalid/a.patch", .bytes = 3, .sha256 = @splat(1), .result_bytes = 5, .result_sha256 = @splat(3), .signature = undefined }, key);
    defer allocator.free(patch);
    const json = try build(allocator, identity, &.{full}, &.{patch});
    defer allocator.free(json);
    try std.testing.checkAllAllocationFailures(allocator, Fixture.run, .{ json, update.Policy{ .identity = identity, .target = "linux-x86_64", .current_version = .{ .major = 1, .minor = 0, .patch = 0 }, .public_key = key.public_key.toBytes() } });
}
