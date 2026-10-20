//! Uploads to Amazon S3 and services that speak its API, such as
//! Cloudflare R2: each object is one PUT signed with AWS Signature
//! Version 4. Credentials come from AWS_ACCESS_KEY_ID,
//! AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN and are never stored.
const std = @import("std");

pub const Bucket = struct {
    name: []const u8,
    /// The directory of the files in the bucket, as "my-app"; "" is its root.
    prefix: []const u8 = "",
    /// Default: AWS_REGION, else AWS_DEFAULT_REGION, else us-east-1.
    region: ?[]const u8 = null,
    /// The service's URL, as "https://ACCOUNT.r2.cloudflarestorage.com";
    /// null is Amazon S3 in the region.
    endpoint: ?[]const u8 = null,
    /// Names the bucket in the path rather than the host. Default: with
    /// an endpoint, or for a bucket name with dots, which virtual hosts'
    /// certificates do not cover.
    path_style: ?bool = null,
};

pub const Credentials = struct {
    access_key: []const u8,
    secret_key: []const u8,
    session_token: ?[]const u8 = null,
};

pub const Error = error{ MissingBucket, InvalidEndpoint, MissingCredentials };

/// A bucket ready for uploads. Strings are borrowed from the Bucket,
/// Credentials and environment it was made from.
pub const Client = struct {
    bucket: []const u8,
    prefix: []const u8,
    region: []const u8,
    scheme: []const u8,
    /// Host, with a port when the endpoint names one.
    host: []const u8,
    path_style: bool,
    credentials: Credentials,

    pub fn init(bucket: Bucket, credentials: Credentials, environment: *const std.process.EnvMap) Error!Client {
        if (bucket.name.len == 0) return error.MissingBucket;
        if (credentials.access_key.len == 0 or credentials.secret_key.len == 0) return error.MissingCredentials;
        const region = bucket.region orelse environment.get("AWS_REGION") orelse environment.get("AWS_DEFAULT_REGION") orelse "us-east-1";
        var client: Client = .{
            .bucket = bucket.name,
            .prefix = std.mem.trim(u8, bucket.prefix, "/"),
            .region = region,
            .scheme = "https",
            .host = "",
            .path_style = bucket.endpoint != null or std.mem.indexOfScalar(u8, bucket.name, '.') != null,
            .credentials = credentials,
        };
        if (bucket.path_style) |path_style| client.path_style = path_style;
        if (bucket.endpoint) |endpoint| {
            const uri = std.Uri.parse(endpoint) catch return error.InvalidEndpoint;
            if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return error.InvalidEndpoint;
            const host = uri.host orelse return error.InvalidEndpoint;
            if (host != .percent_encoded or host.percent_encoded.len == 0) return error.InvalidEndpoint;
            const path = switch (uri.path) {
                inline else => |text| text,
            };
            // The endpoint is the service's; the bucket is named apart.
            if (std.mem.trim(u8, path, "/").len != 0 or uri.query != null) return error.InvalidEndpoint;
            client.scheme = uri.scheme;
            const authority_start = std.mem.indexOf(u8, endpoint, "//").? + 2;
            const authority_end = std.mem.indexOfAnyPos(u8, endpoint, authority_start, "/?#") orelse endpoint.len;
            client.host = endpoint[authority_start..authority_end];
        }
        return client;
    }

    /// The bucket from the environment's credentials.
    pub fn fromEnvironment(bucket: Bucket, environment: *const std.process.EnvMap) Error!Client {
        return init(bucket, .{
            .access_key = environment.get("AWS_ACCESS_KEY_ID") orelse "",
            .secret_key = environment.get("AWS_SECRET_ACCESS_KEY") orelse "",
            .session_token = environment.get("AWS_SESSION_TOKEN"),
        }, environment);
    }

    /// The key of the file `name`, under the prefix. Caller frees.
    pub fn key(self: *const Client, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        if (self.prefix.len == 0) return allocator.dupe(u8, name);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.prefix, name });
    }

    /// Host and escaped path of the object. Caller frees both.
    pub fn location(self: *const Client, allocator: std.mem.Allocator, object: []const u8) !struct { host: []u8, path: []u8 } {
        var path: std.Io.Writer.Allocating = .init(allocator);
        errdefer path.deinit();
        if (self.path_style) {
            try path.writer.writeByte('/');
            try escape(&path.writer, self.bucket);
        }
        try path.writer.writeByte('/');
        try escape(&path.writer, object);
        const service = if (self.host.len > 0)
            try allocator.dupe(u8, self.host)
        else
            try std.fmt.allocPrint(allocator, "s3.{s}.amazonaws.com", .{self.region});
        if (self.path_style) return .{ .host = service, .path = try path.toOwnedSlice() };
        defer allocator.free(service);
        const host = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ self.bucket, service });
        return .{ .host = host, .path = try path.toOwnedSlice() };
    }
};

pub const Object = struct {
    content_type: []const u8 = "application/octet-stream",
    /// "no-cache" for files whose names stay from release to release.
    cache_control: ?[]const u8 = null,
};

/// Called as the body goes out.
pub const Progress = struct {
    context: *anyopaque,
    sent: *const fn (context: *anyopaque, sent: u64, total: u64) void,
};

pub const PutError = error{UploadFailed} || std.mem.Allocator.Error;

/// Puts `bytes` at `object`. A failed upload writes the service's reason
/// to `reason`, as "403 Forbidden: AccessDenied: ...".
pub fn put(allocator: std.mem.Allocator, http: *std.http.Client, client: *const Client, object: []const u8, bytes: []const u8, info: Object, progress: ?Progress, reason: *std.Io.Writer) !void {
    const place = try client.location(allocator, object);
    defer allocator.free(place.host);
    defer allocator.free(place.path);
    const url = try std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ client.scheme, place.host, place.path });
    defer allocator.free(url);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const payload_hash = std.fmt.bytesToHex(digest, .lower);
    var stamp_buffer: [16]u8 = undefined;
    const stamp = timestamp(&stamp_buffer, std.time.timestamp());
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "host", .value = place.host });
    try headers.append(allocator, .{ .name = "x-amz-content-sha256", .value = &payload_hash });
    try headers.append(allocator, .{ .name = "x-amz-date", .value = stamp });
    if (client.credentials.session_token) |token| try headers.append(allocator, .{ .name = "x-amz-security-token", .value = token });
    var authorization_buffer: [512]u8 = undefined;
    const authorization = try authorize(&authorization_buffer, client, "PUT", place.path, headers.items, &payload_hash, stamp);
    var extra: std.ArrayList(std.http.Header) = .empty;
    defer extra.deinit(allocator);
    // std.http writes the host itself, from the URL.
    try extra.appendSlice(allocator, headers.items[1..]);
    try extra.append(allocator, .{ .name = "authorization", .value = authorization });
    if (info.cache_control) |value| try extra.append(allocator, .{ .name = "cache-control", .value = value });

    const uri = std.Uri.parse(url) catch return error.UploadFailed;
    var request = http.request(.PUT, uri, .{
        // S3 answers a request for another region with a redirect, which
        // must not become a GET.
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = info.content_type }, .user_agent = .{ .override = "ziggurat" }, .accept_encoding = .omit },
        .extra_headers = extra.items,
    }) catch |err| return fail(reason, "{s}", .{@errorName(err)});
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = bytes.len };
    var body = request.sendBodyUnflushed(&.{}) catch |err| return fail(reason, "{s}", .{@errorName(err)});
    const chunk = 256 * 1024;
    var sent: usize = 0;
    while (sent < bytes.len) {
        const end = @min(bytes.len, sent + chunk);
        body.writer.writeAll(bytes[sent..end]) catch |err| return fail(reason, "{s}", .{@errorName(err)});
        sent = end;
        if (progress) |p| p.sent(p.context, sent, bytes.len);
    }
    body.end() catch |err| return fail(reason, "{s}", .{@errorName(err)});
    request.connection.?.flush() catch |err| return fail(reason, "{s}", .{@errorName(err)});
    var response = request.receiveHead(&.{}) catch |err| return fail(reason, "{s}", .{@errorName(err)});
    const status = response.head.status;
    // Never discard through `response.reader` here: for a PUT it returns
    // `std.Io.Reader.ending`, a constant that discarding writes to, which
    // faults where constants are read-only (LLVM builds). The connection is
    // not kept alive, so an unread success body is dropped with it.
    if (status.class() == .success) return;
    var bucket_region: [64]u8 = undefined;
    var bucket_region_len: usize = 0;
    var iterator = response.head.iterateHeaders();
    while (iterator.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "x-amz-bucket-region")) {
        bucket_region_len = @min(header.value.len, bucket_region.len);
        @memcpy(bucket_region[0..bucket_region_len], header.value[0..bucket_region_len]);
    };
    var text: [64 * 1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&text);
    var transfer: [64]u8 = undefined;
    // `response.reader` gives a PUT no body, so read the error through the
    // request's own body reader.
    const head = response.head;
    _ = request.reader.bodyReader(&transfer, head.transfer_encoding, head.content_length).streamRemaining(&sink) catch {};
    reason.print("{d} {s}", .{ @intFromEnum(status), status.phrase() orelse "" }) catch {};
    // S3 explains errors in XML.
    const xml = sink.buffered();
    if (element(xml, "Code")) |code| reason.print(": {s}: {s}", .{ code, element(xml, "Message") orelse "" }) catch {};
    const region = bucket_region[0..bucket_region_len];
    if (region.len > 0 and !std.mem.eql(u8, region, client.region)) reason.print(" (the bucket is in {s}: pass --region {s})", .{ region, region }) catch {};
    return error.UploadFailed;
}

fn fail(reason: *std.Io.Writer, comptime format: []const u8, arguments: anytype) error{UploadFailed} {
    reason.print(format, arguments) catch {};
    return error.UploadFailed;
}

fn element(xml: []const u8, comptime name: []const u8) ?[]const u8 {
    const open = "<" ++ name ++ ">";
    const start = (std.mem.indexOf(u8, xml, open) orelse return null) + open.len;
    const end = std.mem.indexOfPos(u8, xml, start, "</" ++ name ++ ">") orelse return null;
    return xml[start..end];
}

/// `YYYYMMDDTHHMMSSZ` for a Unix time.
pub fn timestamp(buffer: *[16]u8, seconds: i64) []const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(seconds, 0)) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        day.year, month.month.numeric(), month.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// The Authorization header of a request without a query, signing
/// `headers` (lower-case names, sorted, the host first is fine: they are
/// sorted here) and a payload of SHA-256 `payload_hash`.
pub fn authorize(buffer: []u8, client: *const Client, method: []const u8, path: []const u8, headers: []const std.http.Header, payload_hash: []const u8, stamp: []const u8) ![]const u8 {
    var sorted: [8]std.http.Header = undefined;
    @memcpy(sorted[0..headers.len], headers);
    std.mem.sort(std.http.Header, sorted[0..headers.len], {}, struct {
        fn less(_: void, a: std.http.Header, b: std.http.Header) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var request: Sha256 = .init(.{});
    request.update(method);
    request.update("\n");
    request.update(path);
    request.update("\n\n");
    for (sorted[0..headers.len]) |header| {
        request.update(header.name);
        request.update(":");
        request.update(std.mem.trim(u8, header.value, " \t"));
        request.update("\n");
    }
    request.update("\n");
    var signed_buffer: [160]u8 = undefined;
    var signed: std.Io.Writer = .fixed(&signed_buffer);
    for (sorted[0..headers.len], 0..) |header, index| {
        if (index > 0) try signed.writeByte(';');
        try signed.writeAll(header.name);
    }
    request.update(signed.buffered());
    request.update("\n");
    request.update(payload_hash);
    const request_hash = std.fmt.bytesToHex(request.finalResult(), .lower);

    const date = stamp[0..8];
    var scope_buffer: [96]u8 = undefined;
    const scope = try std.fmt.bufPrint(&scope_buffer, "{s}/{s}/s3/aws4_request", .{ date, client.region });
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var secret_buffer: [256]u8 = undefined;
    const secret = try std.fmt.bufPrint(&secret_buffer, "AWS4{s}", .{client.credentials.secret_key});
    var signing: [32]u8 = undefined;
    Hmac.create(&signing, date, secret);
    for ([_][]const u8{ client.region, "s3", "aws4_request" }) |part| Hmac.create(&signing, part, &signing);
    var mac: Hmac = .init(&signing);
    mac.update("AWS4-HMAC-SHA256\n");
    mac.update(stamp);
    mac.update("\n");
    mac.update(scope);
    mac.update("\n");
    mac.update(&request_hash);
    var signature: [32]u8 = undefined;
    mac.final(&signature);
    return std.fmt.bufPrint(buffer, "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{
        client.credentials.access_key, scope, signed.buffered(), std.fmt.bytesToHex(signature, .lower),
    });
}

/// Escapes a key for a URL path as Signature Version 4 wants it: every
/// byte but letters, digits, "-._~" and "/".
pub fn escape(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~/", byte) != null) {
            try writer.writeByte(byte);
        } else try writer.print("%{X:0>2}", .{byte});
    }
}

/// The type an uploaded file is served with.
pub fn contentType(name: []const u8) []const u8 {
    const types = [_][2][]const u8{
        .{ ".json", "application/json" },
        .{ ".zip", "application/zip" },
        .{ ".exe", "application/vnd.microsoft.portable-executable" },
        .{ ".deb", "application/vnd.debian.binary-package" },
        .{ ".gz", "application/gzip" },
        // Readable in a browser before it is piped to sh.
        .{ ".sh", "text/plain; charset=utf-8" },
    };
    for (types) |entry| if (std.mem.endsWith(u8, name, entry[0])) return entry[1];
    return "application/octet-stream";
}

/// Caches must check again the files whose names stay from release to
/// release: the release index and the install script.
pub fn cacheControl(name: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, name, "feed.json") or std.mem.eql(u8, name, "install.sh")) "no-cache" else null;
}

test "signature matches the published example" {
    // The GET example of the Signature Version 4 documentation for S3.
    var environment = std.process.EnvMap.init(std.testing.allocator);
    defer environment.deinit();
    const client = try Client.init(.{ .name = "examplebucket" }, .{
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    }, &environment);
    const empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    var buffer: [512]u8 = undefined;
    const header = try authorize(&buffer, &client, "GET", "/test.txt", &.{
        .{ .name = "x-amz-date", .value = "20130524T000000Z" },
        .{ .name = "host", .value = "examplebucket.s3.amazonaws.com" },
        .{ .name = "range", .value = "bytes=0-9" },
        .{ .name = "x-amz-content-sha256", .value = empty },
    }, empty, "20130524T000000Z");
    try std.testing.expectEqualStrings("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", header);
}

test "locations follow the bucket's style" {
    const allocator = std.testing.allocator;
    var environment = std.process.EnvMap.init(allocator);
    defer environment.deinit();
    try environment.put("AWS_REGION", "eu-west-1");
    const credentials: Credentials = .{ .access_key = "a", .secret_key = "b" };
    const virtual = try Client.init(.{ .name = "apps", .prefix = "/tool/" }, credentials, &environment);
    const object = try virtual.key(allocator, "a b+.zip");
    defer allocator.free(object);
    const place = try virtual.location(allocator, object);
    defer allocator.free(place.host);
    defer allocator.free(place.path);
    try std.testing.expectEqualStrings("apps.s3.eu-west-1.amazonaws.com", place.host);
    try std.testing.expectEqualStrings("/tool/a%20b%2B.zip", place.path);
    const r2 = try Client.init(.{ .name = "apps", .endpoint = "https://account.r2.cloudflarestorage.com", .region = "auto" }, credentials, &environment);
    const other = try r2.location(allocator, "feed.json");
    defer allocator.free(other.host);
    defer allocator.free(other.path);
    try std.testing.expectEqualStrings("account.r2.cloudflarestorage.com", other.host);
    try std.testing.expectEqualStrings("/apps/feed.json", other.path);
    try std.testing.expect((try Client.init(.{ .name = "my.apps" }, credentials, &environment)).path_style);
    try std.testing.expectError(error.InvalidEndpoint, Client.init(.{ .name = "apps", .endpoint = "https://host/bucket" }, credentials, &environment));
    try std.testing.expectError(error.InvalidEndpoint, Client.init(.{ .name = "apps", .endpoint = "ftp://host" }, credentials, &environment));
    try std.testing.expectError(error.MissingCredentials, Client.fromEnvironment(.{ .name = "apps" }, &environment));
    var stamp: [16]u8 = undefined;
    try std.testing.expectEqualStrings("20130524T000000Z", timestamp(&stamp, 1369353600));
    try std.testing.expectEqualStrings("no-cache", cacheControl("install.sh").?);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", contentType("install.sh"));
}

test "put sends a signed object and reports the service's error" {
    const allocator = std.testing.allocator;
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    const Serve = struct {
        fn run(listener: *std.net.Server, seen: *[2][256]u8) void {
            for (0..2) |round| {
                const connection = listener.accept() catch return;
                defer connection.stream.close();
                var read_buffer: [8192]u8 = undefined;
                var write_buffer: [1024]u8 = undefined;
                var reader = connection.stream.reader(&read_buffer);
                var writer = connection.stream.writer(&write_buffer);
                var http_server = std.http.Server.init(reader.interface(), &writer.interface);
                var request = http_server.receiveHead() catch return;
                var line: std.Io.Writer = .fixed(&seen[round]);
                line.print("{s} {s}", .{ @tagName(request.head.method), request.head.target }) catch {};
                var iterator = request.iterateHeaders();
                var signed = false;
                while (iterator.next()) |header| {
                    if (std.ascii.eqlIgnoreCase(header.name, "authorization")) signed = std.mem.startsWith(u8, header.value, "AWS4-HMAC-SHA256 Credential=key/");
                    if (std.ascii.eqlIgnoreCase(header.name, "cache-control")) line.print(" {s}", .{header.value}) catch {};
                }
                var body_buffer: [64]u8 = undefined;
                const body = request.readerExpectNone(&body_buffer);
                var content: [64]u8 = undefined;
                var sink: std.Io.Writer = .fixed(&content);
                _ = body.streamRemaining(&sink) catch {};
                line.print(" {s} {}", .{ sink.buffered(), signed }) catch {};
                if (round == 0) {
                    request.respond("", .{}) catch {};
                } else {
                    request.respond("<Error><Code>AccessDenied</Code><Message>No</Message></Error>", .{ .status = .forbidden, .extra_headers = &.{.{ .name = "x-amz-bucket-region", .value = "eu-west-1" }} }) catch {};
                }
            }
        }
    };
    var seen: [2][256]u8 = .{ @splat(0), @splat(0) };
    const thread = try std.Thread.spawn(.{}, Serve.run, .{ &server, &seen });
    var environment = std.process.EnvMap.init(allocator);
    defer environment.deinit();
    var endpoint_buffer: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}", .{server.listen_address.getPort()});
    const client = try Client.init(.{ .name = "apps", .prefix = "tool", .endpoint = endpoint }, .{ .access_key = "key", .secret_key = "secret" }, &environment);
    var http: std.http.Client = .{ .allocator = allocator };
    defer http.deinit();
    var reason_buffer: [256]u8 = undefined;
    var reason: std.Io.Writer = .fixed(&reason_buffer);
    try put(allocator, &http, &client, "tool/install.sh", "#!/bin/sh\n", .{ .content_type = contentType("install.sh"), .cache_control = "no-cache" }, null, &reason);
    try std.testing.expectError(error.UploadFailed, put(allocator, &http, &client, "tool/a.zip", "zip", .{}, null, &reason));
    thread.join();
    try std.testing.expectEqualStrings("PUT /apps/tool/install.sh no-cache #!/bin/sh\n true", std.mem.sliceTo(&seen[0], 0));
    try std.testing.expectEqualStrings("PUT /apps/tool/a.zip zip true", std.mem.sliceTo(&seen[1], 0));
    try std.testing.expectEqualStrings("403 Forbidden: AccessDenied: No (the bucket is in eu-west-1: pass --region eu-west-1)", reason.buffered());
}
