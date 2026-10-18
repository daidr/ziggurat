const std = @import("std");
const c = @cImport({
    @cDefine("NO_STRICT", "1");
    @cInclude("native_ledger.h");
});
fn count() struct { u32, u32, u64 } {
    var accounts: u32 = 0;
    var blocks: u32 = 0;
    var bytes: u64 = 0;
    c.zda_ledger_counts(&accounts, &blocks, &bytes);
    return .{ accounts, blocks, bytes };
}
test "native ledger bounds all requested storage and range metadata after the owner releases its reference" {
    const initial = count();
    var account: ?*c.ZdaAccount = null;
    try std.testing.expectEqual(c.ZDA_OK, c.zda_account_create(8192, 2, &account));
    var state: c.ZdaStats = undefined;
    c.zda_account_stats(account, &state);
    const baseline = state.bytes;
    var ranges: [2]?*anyopaque = @splat(null);
    for (&ranges) |*range| try std.testing.expectEqual(c.ZDA_OK, c.zda_storage_create(account, c.ZDA_RANGE, 64, range));
    var rejected: ?*anyopaque = undefined;
    try std.testing.expectEqual(c.ZDA_CAPACITY, c.zda_storage_create(account, c.ZDA_RANGE, 1, &rejected));
    try std.testing.expect(rejected == null);
    try std.testing.expectEqual(c.ZDA_CAPACITY, c.zda_storage_create(account, c.ZDA_BLOB, 8192, &rejected));
    c.zda_account_stats(account, &state);
    try std.testing.expectEqual(baseline + 2 * c.zda_storage_footprint(64), state.bytes);
    try std.testing.expectEqual(@as(u32, 2), state.ranges);
    c.zda_account_close(account);
    try std.testing.expectEqual(c.ZDA_CLOSED, c.zda_storage_create(account, c.ZDA_BLOB, 16, &rejected));
    // Closing/freeing the Zig-side owner can drop its Account ref now; these
    // late releases run on a different thread and own only native storage.
    c.zda_account_release(account);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(blocks: [2]?*anyopaque) void {
            for (blocks) |block| c.zda_storage_release(block);
        }
    }.run, .{ranges});
    thread.join();
    try std.testing.expectEqualDeep(initial, count());
}
test "concurrent range creation has a bounded native ledger and no historical growth" {
    const initial = count();
    var account: ?*c.ZdaAccount = null;
    try std.testing.expectEqual(c.ZDA_OK, c.zda_account_create(32768, 4, &account));
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, struct {
        fn run(ledger: ?*c.ZdaAccount) void {
            for (0..2000) |_| {
                var range: ?*anyopaque = null;
                const result = c.zda_storage_create(ledger, c.ZDA_RANGE, 96, &range);
                std.debug.assert(result == c.ZDA_OK or result == c.ZDA_CAPACITY);
                if (result == c.ZDA_OK) c.zda_storage_release(range);
            }
        }
    }.run, .{account});
    for (threads) |thread| thread.join();
    var stats: c.ZdaStats = undefined;
    c.zda_account_stats(account, &stats);
    try std.testing.expectEqual(@as(u32, 0), stats.ranges);
    try std.testing.expect(stats.peak_bytes <= stats.byte_limit);
    c.zda_account_release(account);
    try std.testing.expectEqualDeep(initial, count());
}
test "host candidate staging and native metadata share one atomic byte ceiling" {
    const initial = count();
    var account: ?*c.ZdaAccount = null;
    try std.testing.expectEqual(c.ZDA_OK, c.zda_account_create(16384, 4, &account));
    try std.testing.expectEqual(c.ZDA_OK, c.zda_account_reserve_host(account, 8192));
    var rejected: ?*anyopaque = null;
    try std.testing.expectEqual(c.ZDA_CAPACITY, c.zda_storage_create(account, c.ZDA_BLOB, 8192, &rejected));
    var stats: c.ZdaStats = undefined;
    c.zda_account_stats(account, &stats);
    try std.testing.expectEqual(@as(u64, 8192), stats.host_bytes);
    try std.testing.expect(stats.bytes > stats.host_bytes);
    c.zda_account_close(account);
    c.zda_account_release(account);
    try std.testing.expectEqual(c.ZDA_CLOSED, c.zda_account_reserve_host(account, 1));
    // The successful host reservation owns the native account independently
    // until the host frees its staging, even after ingress and owner close.
    c.zda_account_release_host(account, 8192);
    try std.testing.expectEqualDeep(initial, count());
}
