const std = @import("std");
const http = @import("ziggurat_http_response");
const policy = @import("policy.zig");

pub const capacity = 128;
pub const Route = struct {
    /// Canonical path relative to the mount. '/' names the mount itself.
    /// A route is never a filesystem path or a directory authorization.
    path: []const u8,
    mime: []const u8 = "application/octet-stream",
    bytes: []const u8,
};
pub const Limits = struct {
    max_routes: u16 = capacity,
    bytes: usize = 32 * 1024 * 1024,
    max_body_bytes: usize = 16 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.max_routes > capacity or self.bytes == 0 or self.bytes > 256 * 1024 * 1024 or
            self.max_body_bytes == 0 or self.max_body_bytes > 16 * 1024 * 1024) return error.InvalidSiteLimits;
    }
};

/// These headers are applied by Site's static and 404 responses. Dynamic and
/// file handlers must explicitly include them in their own responses; borrowing
/// this list is not evidence that any response has applied the policy.
pub const policy_headers = [_]http.Header{
    .{ .name = "Content-Security-Policy", .value = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'" },
    .{ .name = "Cache-Control", .value = "no-store" },
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
};

/// Pure borrowed merge. The result and every input byte remain borrowed until
/// the response entry point returns. No response or transport is changed here.
pub fn mergePolicyHeaders(extra: []const http.Header, output: *[16]http.Header) ![]const http.Header {
    if (extra.len > output.len - policy_headers.len) return error.TooManyResponseHeaders;
    for (extra) |header| for (policy_headers) |fixed| {
        if (std.ascii.eqlIgnoreCase(header.name, fixed.name)) return error.ReservedSiteHeader;
    };
    // extra can be any slice of output. Snapshot into an independent candidate
    // and publish only after every validation succeeds, preserving output on
    // failure as well as allowing an ordinary in-place merge.
    var candidate: [16]http.Header = undefined;
    @memcpy(candidate[0..policy_headers.len], &policy_headers);
    @memcpy(candidate[policy_headers.len..][0..extra.len], extra);
    const result = candidate[0 .. policy_headers.len + extra.len];
    try http.validateResponse(.{ .headers = result }, 0);
    @memcpy(output[0..result.len], result);
    return output[0..result.len];
}

/// One immutable allocation. Descriptors are captured before calling the
/// allocator; all route bytes must remain stable until init returns. Full
/// ownership precedes route/MIME validation and sorting. Do not copy owners.
pub const Owned = struct {
    allocator: std.mem.Allocator,
    storage: ?[]align(@alignOf(Route)) u8,
    mount: []const u8,
    routes: []const Route,

    pub fn init(allocator: std.mem.Allocator, mount: []const u8, input: []const Route, limits: Limits) !Owned {
        try limits.validate();
        if (input.len > limits.max_routes) return error.TooManySiteRoutes;
        if (mount.len == 0 or mount.len > policy.prefix_capacity) return error.InvalidPrefix;
        return capture(allocator, mount, input, limits);
    }
    noinline fn capture(allocator: std.mem.Allocator, mount: []const u8, input: []const Route, limits: Limits) !Owned {
        var descriptors: [capacity]Route = undefined;
        @memcpy(descriptors[0..input.len], input);
        var bytes = try std.math.mul(usize, input.len, @sizeOf(Route));
        bytes = try std.math.add(usize, bytes, mount.len);
        for (descriptors[0..input.len]) |row| {
            if (row.path.len == 0 or row.path.len > policy.path_capacity) return error.InvalidSiteRoute;
            if (row.mime.len == 0 or row.mime.len > 127) return error.InvalidMime;
            if (row.bytes.len > limits.max_body_bytes) return error.ResourceTooLarge;
            bytes = try std.math.add(usize, bytes, row.path.len);
            bytes = try std.math.add(usize, bytes, row.mime.len);
            bytes = try std.math.add(usize, bytes, row.bytes.len);
        }
        if (bytes > limits.bytes) return error.SiteBudgetExceeded;
        const storage = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(Route)), bytes);
        errdefer allocator.free(storage);
        const rows = @as([*]Route, @ptrCast(storage.ptr))[0..input.len];
        var cursor = input.len * @sizeOf(Route);
        const owned_mount = copy(storage, &cursor, mount);
        for (rows, descriptors[0..input.len]) |*row, descriptor| row.* = .{
            .path = copy(storage, &cursor, descriptor.path),
            .mime = copy(storage, &cursor, descriptor.mime),
            .bytes = copy(storage, &cursor, descriptor.bytes),
        };
        // Use precisely the Endpoint mount parser. No caller input is read
        // after ownership, and the dummy credential is never a live secret.
        var mount_policy: policy.Policy = undefined;
        try mount_policy.captureInto(1, owned_mount, @splat(0));
        for (rows) |row| {
            if (!validPath(row.path) or owned_mount.len - 1 + row.path.len > policy.path_capacity) return error.InvalidSiteRoute;
            try http.validateResponse(.{ .mime = row.mime, .headers = &policy_headers, .bytes = row.bytes }, limits.max_body_bytes);
        }
        std.mem.sort(Route, rows, {}, lessThan);
        for (rows, 0..) |row, index| if (index != 0 and std.mem.eql(u8, rows[index - 1].path, row.path)) return error.DuplicateSiteRoute;
        return .{ .allocator = allocator, .storage = storage, .mount = owned_mount, .routes = rows };
    }
    fn copy(storage: []u8, cursor: *usize, input: []const u8) []const u8 {
        const result = storage[cursor.*..][0..input.len];
        @memcpy(result, input);
        cursor.* += input.len;
        return result;
    }
    fn lessThan(_: void, first: Route, second: Route) bool {
        return std.mem.order(u8, first.path, second.path) == .lt;
    }
    pub fn deinit(self: *Owned) void {
        const storage = self.storage;
        self.storage = null;
        self.mount = "";
        self.routes = &.{};
        if (storage) |value| self.allocator.free(value);
    }
    /// Endpoint has already admitted its canonical SDK path. Strip only the
    /// exact mount boundary, then require this narrower literal route grammar.
    /// Query is a separate Request field and never participates in lookup.
    pub fn relative(self: *const Owned, full_path: []const u8) ?[]const u8 {
        if (self.mount.len == 0 or !std.mem.startsWith(u8, full_path, self.mount)) return null;
        const path = full_path[self.mount.len - 1 ..];
        return if (validPath(path)) path else null;
    }
    pub fn find(self: *const Owned, relative_path: []const u8) ?Route {
        if (!validPath(relative_path)) return null;
        var low: usize = 0;
        var high = self.routes.len;
        while (low < high) {
            const index = low + (high - low) / 2;
            switch (std.mem.order(u8, relative_path, self.routes[index].path)) {
                .eq => return self.routes[index],
                .lt => high = index,
                .gt => low = index + 1,
            }
        }
        return null;
    }
};

/// A deliberately literal ASCII grammar for the canonical SDK path. Remaining
/// percent escapes, Unicode, query/fragment, repeated slashes and dot segments
/// are rejected. The SDK may already normalize unreserved escapes; this never
/// authorizes filesystem fallback. A single final slash is permitted.
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > policy.path_capacity or path[0] != '/') return false;
    for (path) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '-' or byte == '_' or byte == '.')) return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (part.len == 0 and parts.index != null) return false;
    }
    return true;
}

fn fixture(allocator: std.mem.Allocator) !void {
    var table = try Owned.init(allocator, "/private/", &.{
        .{ .path = "/z.bin", .bytes = "\x00\xffbody" },
        .{ .path = "/", .mime = "text/html; charset=utf-8", .bytes = "<title>甲😀</title>" },
        .{ .path = "/app.js", .mime = "text/javascript", .bytes = "return;" },
    }, .{});
    defer table.deinit();
    try std.testing.expectEqualStrings("/", table.routes[0].path);
    try std.testing.expectEqualStrings("<title>甲😀</title>", table.find("/").?.bytes);
    try std.testing.expectEqualStrings("\x00\xffbody", table.find("/z.bin").?.bytes);
    try std.testing.expectEqualStrings("/app.js", table.relative("/private/app.js").?);
    try std.testing.expect(table.relative("/private-other/app.js") == null);
    try std.testing.expect(table.relative("/private") == null);
    try std.testing.expect(table.find("/missing") == null);
    try std.testing.expect(table.relative("/private/%2fsecret") == null);
}
test "site table owns and sorts every byte with complete allocation rollback" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fixture, .{});
}
test "site input limits and route grammar never authorize directories or aliases" {
    for ([_][]const u8{ "", "relative", "//", "/a//b", "/./", "/../secret", "/a/..", "/a/.", "/%61", "/%2e%2e/", "/a?x", "/a#x", "/a\\b", "/a:b", "/甲" }) |path| {
        try std.testing.expect(!validPath(path));
        try std.testing.expectError(error.InvalidSiteRoute, Owned.init(std.testing.allocator, "/", &.{.{ .path = path, .bytes = "" }}, .{}));
    }
    try std.testing.expect(validPath("/") and validPath("/a/") and validPath("/a.b-c_d"));
    try std.testing.expectError(error.InvalidPrefix, Owned.init(std.testing.allocator, "/private", &.{}, .{}));
    try std.testing.expectError(error.DuplicateSiteRoute, Owned.init(std.testing.allocator, "/", &.{ .{ .path = "/a", .bytes = "a" }, .{ .path = "/a", .bytes = "b" } }, .{}));
    try std.testing.expectError(error.SiteBudgetExceeded, Owned.init(std.testing.failing_allocator, "/", &.{.{ .path = "/", .bytes = "a" }}, .{ .bytes = 1 }));
    try std.testing.expectError(error.ResourceTooLarge, Owned.init(std.testing.failing_allocator, "/", &.{.{ .path = "/", .bytes = "ab" }}, .{ .max_body_bytes = 1 }));
    try std.testing.expectError(error.InvalidSiteLimits, Owned.init(std.testing.failing_allocator, "/", &.{}, .{ .bytes = 0 }));
}
test "policy header merge is explicit bounded and rejects replacement or duplicates" {
    var rows: [16]http.Header = undefined;
    const merged = try mergePolicyHeaders(&.{.{ .name = "X-Host", .value = "explicit" }}, &rows);
    try std.testing.expectEqual(@as(usize, 4), merged.len);
    try std.testing.expectEqualStrings("no-store", merged[1].value);
    for (policy_headers) |header| try std.testing.expectError(error.ReservedSiteHeader, mergePolicyHeaders(&.{.{ .name = header.name, .value = "weakened" }}, &rows));
    try std.testing.expectError(error.DuplicateResponseHeader, mergePolicyHeaders(&.{ .{ .name = "X-a", .value = "x" }, .{ .name = "x-A", .value = "y" } }, &rows));
    try std.testing.expectError(error.ReservedResponseHeader, mergePolicyHeaders(&.{.{ .name = "Content-Length", .value = "1" }}, &rows));
    const extra = @as([14]http.Header, @splat(.{ .name = "X-a", .value = "x" }));
    try std.testing.expectError(error.TooManyResponseHeaders, mergePolicyHeaders(&extra, &rows));
}
test "policy header merge snapshots aliases and publishes nothing on validation failure" {
    var rows = @as([16]http.Header, @splat(.{ .name = "X-sentinel", .value = "retained" }));
    const merged = try mergePolicyHeaders(rows[0..1], &rows);
    try std.testing.expectEqualStrings("X-sentinel", merged[3].name);
    try std.testing.expectEqualStrings("retained", merged[3].value);
    const sentinel = rows;
    try std.testing.expectError(error.InvalidResponseHeader, mergePolicyHeaders(&.{.{ .name = "bad\nname", .value = "value" }}, &rows));
    try std.testing.expectEqualDeep(sentinel, rows);
    try std.testing.expectError(error.ReservedSiteHeader, mergePolicyHeaders(rows[0..1], &rows));
    try std.testing.expectEqualDeep(sentinel, rows);
}
test "site descriptor capture precedes caller allocator mutation and free withdraws first" {
    const Probe = struct {
        input: *Route,
        owned: ?*Owned = null,
        freed: usize = 0,
        fn alloc(ptr: *anyopaque, count: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.input.* = .{ .path = "/changed", .bytes = "changed" };
            return std.testing.allocator.rawAlloc(count, alignment, ra);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.freed += 1;
            const owned = self.owned.?;
            std.debug.assert(owned.storage == null and owned.mount.len == 0 and owned.routes.len == 0);
            owned.deinit();
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var route: Route = .{ .path = "/original", .mime = "text/plain", .bytes = "owned" };
    var probe: Probe = .{ .input = &route };
    const allocator: std.mem.Allocator = .{ .ptr = &probe, .vtable = &.{ .alloc = Probe.alloc, .free = Probe.free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    var owned = try Owned.init(allocator, "/", @as([*]Route, @ptrCast(&route))[0..1], .{});
    probe.owned = &owned;
    try std.testing.expectEqualStrings("owned", owned.find("/original").?.bytes);
    try std.testing.expect(owned.find("/changed") == null);
    owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.freed);
}
