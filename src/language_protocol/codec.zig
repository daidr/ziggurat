const std = @import("std");

pub const Limits = struct {
    header_bytes: usize = 8192,
    body_bytes: usize = 1024 * 1024,
    json_bytes: usize = 8 * 1024 * 1024,
    tokens: usize = 65536,
    depth: usize = 64,
    pub fn validate(self: Limits) !void {
        if (self.header_bytes < 24 or self.header_bytes > 65536 or self.body_bytes == 0 or self.body_bytes > 16 * 1024 * 1024 or self.json_bytes < @sizeOf(MessageState) or self.json_bytes > 128 * 1024 * 1024 or self.tokens == 0 or self.tokens > 1024 * 1024 or self.depth == 0 or self.depth > 128) return error.InvalidLimits;
    }
};
/// A body borrow ends at the next push/reset/close. One push stops exactly at
/// one message boundary; the caller retains and retries the unconsumed suffix.
pub const Progress = struct { consumed: usize, body: ?[]const u8 = null };
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    header: []u8,
    body: []u8,
    header_len: usize = 0,
    body_len: usize = 0,
    expected: ?usize = null,
    ready: bool = false,
    failed: bool = false,
    pub fn init(allocator: std.mem.Allocator, limits: Limits) !Decoder {
        try limits.validate();
        const header = try allocator.alloc(u8, limits.header_bytes);
        errdefer allocator.free(header);
        const body = try allocator.alloc(u8, limits.body_bytes);
        return .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .header = header, .body = body };
    }
    pub fn deinit(self: *Decoder) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
        const allocator = self.allocator;
        const header = self.header;
        const body = self.body;
        self.header = &.{};
        self.body = &.{};
        self.failed = true;
        allocator.free(header);
        allocator.free(body);
    }
    pub fn reset(self: *Decoder) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.header.len == 0) return error.Closed;
        self.header_len = 0;
        self.body_len = 0;
        self.expected = null;
        self.ready = false;
        self.failed = false;
    }
    pub fn push(self: *Decoder, bytes: []const u8) !Progress {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.failed) return error.DecoderFailed;
        errdefer self.failed = true;
        if (self.ready) try self.reset();
        var at: usize = 0;
        while (at < bytes.len) {
            if (self.expected) |expected| {
                const amount = @min(bytes.len - at, expected - self.body_len);
                @memcpy(self.body[self.body_len..][0..amount], bytes[at..][0..amount]);
                at += amount;
                self.body_len += amount;
                if (self.body_len == expected) {
                    self.ready = true;
                    return .{ .consumed = at, .body = self.body[0..expected] };
                }
            } else {
                if (self.header_len == self.header.len) return error.HeaderCapacityExceeded;
                const byte = bytes[at];
                if (byte > 127 or (byte < 32 and byte != '\r' and byte != '\n' and byte != '\t')) return error.InvalidHeader;
                self.header[self.header_len] = byte;
                self.header_len += 1;
                at += 1;
                if (self.header_len >= 4 and std.mem.eql(u8, self.header[self.header_len - 4 .. self.header_len], "\r\n\r\n")) self.expected = try contentLength(self.header[0 .. self.header_len - 2], self.body.len);
            }
        }
        return .{ .consumed = at };
    }
};
fn contentLength(header: []const u8, limit: usize) !usize {
    var length: ?usize = null;
    var content_type = false;
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const key = line[0..colon];
        if (key.len == 0) return error.InvalidHeader;
        for (line) |byte| if (byte == '\r' or byte == '\n') return error.InvalidHeader;
        for (key) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return error.InvalidHeader;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "Content-Length")) {
            if (length != null) return error.DuplicateContentLength;
            if (value.len == 0) return error.InvalidContentLength;
            for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidContentLength;
            length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
            if (length.? == 0) return error.InvalidContentLength;
            if (length.? > limit) return error.BodyCapacityExceeded;
        } else if (std.ascii.eqlIgnoreCase(key, "Content-Type")) {
            if (content_type) return error.DuplicateContentType;
            content_type = true;
            var pieces = std.mem.splitScalar(u8, value, ';');
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, pieces.next().?, " \t"), "application/vscode-jsonrpc")) return error.UnsupportedContentType;
            var seen_charset = false;
            while (pieces.next()) |piece| {
                const part = std.mem.trim(u8, piece, " \t");
                const equal = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidHeader;
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, part[0..equal], " \t"), "charset")) return error.UnsupportedContentType;
                if (seen_charset) return error.InvalidHeader;
                seen_charset = true;
                var charset = std.mem.trim(u8, part[equal + 1 ..], " \t");
                if (charset.len >= 2 and charset[0] == '"' and charset[charset.len - 1] == '"') charset = charset[1 .. charset.len - 1];
                if (!std.ascii.eqlIgnoreCase(charset, "utf-8") and !std.ascii.eqlIgnoreCase(charset, "utf8")) return error.UnsupportedCharset;
            }
        }
    }
    return length orelse error.MissingContentLength;
}

// Unbuffered so a structural byte is checked before Stringify descends into
// its next container. Both counting and output stay inside the same limits;
// no allocation or fixed native recursion assertion precedes this gate.
const EncodingWriter = struct {
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    maximum: usize,
    max_depth: usize,
    output: ?[]u8 = null,
    count: usize = 0,
    depth: usize = 0,
    quoted: bool = false,
    escaped: bool = false,
    failure: ?anyerror = null,
    fn fail(self: *EncodingWriter, err: anyerror) std.Io.Writer.Error {
        self.failure = err;
        return error.WriteFailed;
    }
    fn feed(self: *EncodingWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len > self.maximum - self.count) return self.fail(error.BodyCapacityExceeded);
        for (bytes) |byte| {
            if (self.quoted) {
                if (self.escaped) {
                    self.escaped = false;
                } else switch (byte) {
                    '\\' => self.escaped = true,
                    '"' => self.quoted = false,
                    else => {},
                }
            } else switch (byte) {
                '"' => self.quoted = true,
                '[', '{' => {
                    if (self.depth == self.max_depth) return self.fail(error.DepthCapacityExceeded);
                    self.depth += 1;
                },
                ']', '}' => self.depth -|= 1,
                else => {},
            }
        }
        if (self.output) |output| @memcpy(output[self.count..][0..bytes.len], bytes);
        self.count += bytes.len;
    }
    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *EncodingWriter = @alignCast(@fieldParentPtr("writer", writer));
        std.debug.assert(writer.end == 0);
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            try self.feed(part);
            written += part.len;
        }
        const pattern = data[data.len - 1];
        if (pattern.len != 0) {
            if (splat > (self.maximum - self.count) / pattern.len) return self.fail(error.BodyCapacityExceeded);
            for (0..splat) |_| try self.feed(pattern);
            written += pattern.len * splat;
        }
        return written;
    }
};

/// Linear independent bytes. Ownership transfers only when the host accepts
/// its transport responsibility; encoding itself makes no synchronization claim.
pub const Packet = struct {
    allocator: std.mem.Allocator,
    bytes: ?[]u8,
    pub fn deinit(self: *Packet) void {
        const bytes = self.bytes orelse return;
        self.bytes = null;
        self.allocator.free(bytes);
    }
    pub fn json(allocator: std.mem.Allocator, value: anytype, limits: Limits) !Packet {
        try limits.validate();
        var counter: EncodingWriter = .{ .maximum = limits.body_bytes, .max_depth = limits.depth };
        std.json.Stringify.value(value, .{}, &counter.writer) catch |err| return counter.failure orelse err;
        if (counter.count == 0) return error.BodyCapacityExceeded;
        var header: [64]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&header, "Content-Length: {d}\r\n\r\n", .{counter.count});
        if (prefix.len > limits.header_bytes) return error.HeaderCapacityExceeded;
        const bytes = try allocator.alloc(u8, prefix.len + counter.count);
        errdefer allocator.free(bytes);
        @memcpy(bytes[0..prefix.len], prefix);
        var output: EncodingWriter = .{ .maximum = counter.count, .max_depth = limits.depth, .output = bytes[prefix.len..] };
        std.json.Stringify.value(value, .{}, &output.writer) catch return error.EncodingChanged;
        if (output.count != counter.count) return error.EncodingChanged;
        _ = try preflight(bytes[prefix.len..], limits);
        return .{ .allocator = allocator, .bytes = bytes };
    }
};
/// Allocation-free ordinary JSON serialization for already-bounded values.
pub fn valueLength(value: std.json.Value, maximum: usize) !usize {
    var counter: EncodingWriter = .{ .maximum = maximum, .max_depth = 128 };
    std.json.Stringify.value(value, .{}, &counter.writer) catch |err| return counter.failure orelse err;
    return counter.count;
}
pub fn writeValue(value: std.json.Value, output: []u8) !void {
    var writer: EncodingWriter = .{ .maximum = output.len, .max_depth = 128, .output = output };
    std.json.Stringify.value(value, .{}, &writer.writer) catch return error.EncodingChanged;
    if (writer.count != output.len) return error.EncodingChanged;
}

pub const Id = union(enum) { number: i32, text: []const u8, none };
pub const Envelope = union(enum) {
    request: struct { id: Id, method: []const u8, params: ?std.json.Value },
    notification: struct { method: []const u8, params: ?std.json.Value },
    response: struct { id: Id, result: std.json.Value },
    failure: struct { id: Id, code: i32, message: []const u8, data: ?std.json.Value },
};
pub const ParseStats = struct { bytes: usize, peak_bytes: usize, tokens: usize, depth: usize };
/// Stable owner of a bounded JSON tree. Envelope and all Value/string borrows
/// end at close; no input slice or stack allocator context escapes parse.
pub const Message = opaque {
    pub fn parse(allocator: std.mem.Allocator, body: []const u8, limits: Limits) !*Message {
        return parseMode(allocator, body, limits, false);
    }
    /// Explicit continuation capture: number lexemes remain JSON numbers rather
    /// than being rounded through f64. Default parse retains its original path.
    pub fn parseLossless(allocator: std.mem.Allocator, body: []const u8, limits: Limits) !*Message {
        return parseMode(allocator, body, limits, true);
    }
    fn parseMode(allocator: std.mem.Allocator, body: []const u8, limits: Limits, lossless: bool) !*Message {
        try limits.validate();
        const scan = try preflight(body, limits);
        const state = try allocator.create(MessageState);
        state.* = .{ .budget = .{ .child = allocator, .limit = limits.json_bytes, .live = @sizeOf(MessageState), .peak = @sizeOf(MessageState) }, .owner = std.Thread.getCurrentId(), .scan = scan };
        errdefer allocator.destroy(state);
        const parsed = std.json.parseFromSlice(std.json.Value, state.budget.allocator(), body, .{ .allocate = .alloc_always, .max_value_len = limits.body_bytes, .parse_numbers = !lossless }) catch |err| return if (err == error.OutOfMemory and state.budget.denied) error.JsonCapacityExceeded else err;
        errdefer parsed.deinit();
        state.envelope = try envelope(parsed.value);
        state.parsed = parsed;
        return @ptrCast(state);
    }
    pub fn value(self: *const Message) !Envelope {
        const state = cast(@constCast(self));
        try state.check();
        return state.envelope;
    }
    pub fn stats(self: *const Message) !ParseStats {
        const state = cast(@constCast(self));
        try state.check();
        return .{ .bytes = state.budget.live, .peak_bytes = state.budget.peak, .tokens = state.scan.tokens, .depth = state.scan.depth };
    }
    pub fn close(self: *Message) !void {
        const state = cast(self);
        try state.check();
        state.closing = true;
        const allocator = state.budget.child;
        state.parsed.?.deinit();
        allocator.destroy(state);
    }
};
const Scan = struct { tokens: usize, depth: usize };
pub const ValueStats = struct { tokens: usize, depth: usize };
/// Owning ordinary JSON value with lossless number lexemes. Same bounded
/// allocator, owner/close contract as Message, without an RPC envelope.
pub const JsonValue = opaque {
    pub fn parseLossless(allocator: std.mem.Allocator, body: []const u8, limits: Limits) !*JsonValue {
        try limits.validate();
        const scan = try preflight(body, limits);
        const state = try allocator.create(MessageState);
        state.* = .{ .budget = .{ .child = allocator, .limit = limits.json_bytes, .live = @sizeOf(MessageState), .peak = @sizeOf(MessageState) }, .owner = std.Thread.getCurrentId(), .scan = scan };
        errdefer allocator.destroy(state);
        state.parsed = std.json.parseFromSlice(std.json.Value, state.budget.allocator(), body, .{ .allocate = .alloc_always, .max_value_len = limits.body_bytes, .parse_numbers = false }) catch |err| return if (err == error.OutOfMemory and state.budget.denied) error.JsonCapacityExceeded else err;
        return @ptrCast(state);
    }
    pub fn value(self: *JsonValue) !std.json.Value {
        const state: *MessageState = @ptrCast(@alignCast(self));
        try state.check();
        return state.parsed.?.value;
    }
    pub fn close(self: *JsonValue) !void {
        const message: *Message = @ptrCast(self);
        try message.close();
    }
};
/// Validate exactly one ordinary JSON value, including duplicate-key rejection.
/// Temporary tree ownership ends before return; caller supplies its bounded
/// allocator. Number lexemes are not rounded through integer/f64 conversion.
pub fn validateValue(allocator: std.mem.Allocator, body: []const u8, limits: Limits) !ValueStats {
    try limits.validate();
    const scan = try preflight(body, limits);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always, .max_value_len = limits.body_bytes, .parse_numbers = false });
    parsed.deinit();
    return .{ .tokens = scan.tokens, .depth = scan.depth };
}
fn preflight(body: []const u8, limits: Limits) !Scan {
    if (body.len > limits.body_bytes) return error.BodyCapacityExceeded;
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;
    var storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), body);
    defer scanner.deinit();
    var scan: Scan = .{ .tokens = 0, .depth = 0 };
    var depth: usize = 0;
    while (true) {
        const token = try scanner.next();
        if (token == .end_of_document) break;
        if (scan.tokens == limits.tokens) return error.TokenCapacityExceeded;
        scan.tokens += 1;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.depth) return error.DepthCapacityExceeded;
                scan.depth = @max(scan.depth, depth);
            },
            .object_end, .array_end => depth -= 1,
            else => {},
        }
    }
    return scan;
}
fn idOf(value: std.json.Value) !Id {
    return switch (value) {
        .integer, .number_string => .{ .number = std.math.cast(i32, integerValue(value) catch return error.InvalidId) orelse return error.InvalidId },
        .string => |text| .{ .text = text },
        .null => .none,
        else => error.InvalidId,
    };
}
/// Strict decimal integer fields, shared by the normal and lossless modes.
/// Fraction/exponent spellings remain unsupported for typed LSP integers.
pub fn integerValue(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => value.integer,
        .number_string => std.fmt.parseInt(i64, value.number_string, 10) catch error.InvalidInteger,
        else => error.InvalidInteger,
    };
}
fn envelope(root: std.json.Value) !Envelope {
    if (root == .array) return error.UnsupportedBatch;
    if (root != .object) return error.InvalidEnvelope;
    const version = root.object.get("jsonrpc") orelse return error.InvalidEnvelope;
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return error.UnsupportedVersion;
    const id = root.object.get("id");
    const result = root.object.get("result");
    const failure = root.object.get("error");
    if (root.object.get("method")) |method| {
        if (method != .string or method.string.len == 0 or result != null or failure != null) return error.InvalidEnvelope;
        const params = root.object.get("params");
        if (params) |value| if (value != .object and value != .array) return error.InvalidParams;
        if (id) |value| {
            const request_id = try idOf(value);
            if (request_id == .none) return error.InvalidId;
            return .{ .request = .{ .id = request_id, .method = method.string, .params = params } };
        }
        return .{ .notification = .{ .method = method.string, .params = params } };
    }
    if (root.object.get("params") != null or (result == null) == (failure == null)) return error.InvalidEnvelope;
    const response_id = try idOf(id orelse return error.InvalidEnvelope);
    if (result) |value| return .{ .response = .{ .id = response_id, .result = value } };
    const value = failure.?;
    if (value != .object) return error.InvalidEnvelope;
    const code = value.object.get("code") orelse return error.InvalidEnvelope;
    const message = value.object.get("message") orelse return error.InvalidEnvelope;
    if (message != .string) return error.InvalidEnvelope;
    return .{ .failure = .{ .id = response_id, .code = std.math.cast(i32, integerValue(code) catch return error.InvalidEnvelope) orelse return error.InvalidEnvelope, .message = message.string, .data = value.object.get("data") } };
}
const MessageState = struct {
    budget: Budget,
    owner: std.Thread.Id,
    scan: Scan,
    parsed: ?std.json.Parsed(std.json.Value) = null,
    envelope: Envelope = undefined,
    closing: bool = false,
    fn check(self: *const MessageState) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closing) return error.Closed;
    }
};
fn cast(message: *Message) *MessageState {
    return @ptrCast(@alignCast(message));
}
const Budget = struct {
    child: std.mem.Allocator,
    limit: usize,
    live: usize,
    peak: usize,
    denied: bool = false,
    fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        if (bytes > self.limit -| self.live) {
            self.denied = true;
            return null;
        }
        const result = self.child.rawAlloc(bytes, alignment, ret) orelse return null;
        self.live += bytes;
        self.peak = @max(self.peak, self.live);
        return result;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.child.rawFree(bytes, alignment, ret);
        self.live -= bytes.len;
    }
};

test "framing handles every fragmentation boundary and retains coalesced suffix" {
    const a = std.testing.allocator;
    var packet = try Packet.json(a, .{ .jsonrpc = "2.0", .id = 7, .result = "中😀" }, .{});
    defer packet.deinit();
    for (0..packet.bytes.?.len + 1) |split| {
        var decoder = try Decoder.init(a, .{ .body_bytes = 128 });
        defer decoder.deinit();
        const first = try decoder.push(packet.bytes.?[0..split]);
        const body = if (first.body) |body| body else (try decoder.push(packet.bytes.?[split..])).body.?;
        const message = try Message.parse(a, body, .{});
        defer message.close() catch unreachable;
        try std.testing.expectEqualStrings("中😀", (try message.value()).response.result.string);
        const next = try decoder.push(packet.bytes.?);
        try std.testing.expectEqual(packet.bytes.?.len, next.consumed);
    }
    var decoder = try Decoder.init(a, .{ .body_bytes = 128 });
    defer decoder.deinit();
    const joined = try std.mem.concat(a, u8, &.{ packet.bytes.?, packet.bytes.? });
    defer a.free(joined);
    const first = try decoder.push(joined);
    try std.testing.expectEqual(packet.bytes.?.len, first.consumed);
    try std.testing.expect((try decoder.push(joined[first.consumed..])).body != null);
}
test "framing rejects ambiguous lengths encodings and over-budget input until reset" {
    const cases = .{
        .{ "Content-Length: 1\r\nContent-Length: 1\r\n\r\nx", error.DuplicateContentLength },
        .{ "Content-Length: -1\r\n\r\n", error.InvalidContentLength },
        .{ "Content-Length: 129\r\n\r\n", error.BodyCapacityExceeded },
        .{ "Content-Length: 1\r\nContent-Type: application/vscode-jsonrpc; charset=utf-16\r\n\r\nx", error.UnsupportedCharset },
        .{ "X: y\r\n\r\n", error.MissingContentLength },
        .{ "Content Length: 1\r\n\r\nx", error.InvalidHeader },
    };
    inline for (cases) |item| {
        var decoder = try Decoder.init(std.testing.allocator, .{ .body_bytes = 128 });
        defer decoder.deinit();
        try std.testing.expectError(item[1], decoder.push(item[0]));
        try std.testing.expectError(error.DecoderFailed, decoder.push("x"));
        try decoder.reset();
        try std.testing.expectEqualStrings("{}", (try decoder.push("content-length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf8\r\n\r\n{}")).body.?);
    }
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var packet = try Packet.json(allocator, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .text = "UTF8 中😀", .items = .{ 1, 2, 3 } } }, .{});
    defer packet.deinit();
    var decoder = try Decoder.init(allocator, .{ .body_bytes = 1024 });
    defer decoder.deinit();
    const message = try Message.parse(allocator, (try decoder.push(packet.bytes.?)).body.?, .{});
    defer message.close() catch unreachable;
    try std.testing.expectEqualStrings("textDocument/didOpen", (try message.value()).notification.method);
}
test "JSON ownership envelopes budgets and all allocation failures are explicit" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
    const input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"text\":\"x\"}}";
    const message = try Message.parse(std.testing.allocator, input, .{});
    defer message.close() catch unreachable;
    const stats = try message.stats();
    try std.testing.expectError(error.JsonCapacityExceeded, Message.parse(std.testing.allocator, input, .{ .json_bytes = stats.peak_bytes - 1 }));
    try std.testing.expectError(error.DepthCapacityExceeded, Message.parse(std.testing.allocator, input, .{ .depth = 1 }));
    try std.testing.expectError(error.TokenCapacityExceeded, Message.parse(std.testing.allocator, input, .{ .tokens = 1 }));
    try std.testing.expectError(error.DuplicateField, Message.parse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"id\":2,\"result\":null}", .{}));
    try std.testing.expectError(error.InvalidEnvelope, Message.parse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null,\"error\":null}", .{}));
    try std.testing.expectError(error.UnsupportedBatch, Message.parse(std.testing.allocator, "[]", .{}));
    try std.testing.expectError(error.InvalidId, Message.parse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2147483648,\"result\":null}", .{}));
    try std.testing.expectError(error.BodyCapacityExceeded, Packet.json(std.testing.allocator, .{ .long = "value" }, .{ .body_bytes = 1 }));
}

test "encoding byte and nesting limits reject before allocation or deep Stringify recursion" {
    var rejecting = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const a = rejecting.allocator();
    var values: [512]std.json.Value = undefined;
    for (&values, 0..) |*value, index| value.* = if (index + 1 == values.len) .null else .{ .array = .{ .items = values[index + 1 ..][0..1], .capacity = 1, .allocator = std.testing.allocator } };
    try std.testing.expectError(error.DepthCapacityExceeded, Packet.json(a, values[0], .{ .depth = 128 }));
    try std.testing.expectError(error.BodyCapacityExceeded, Packet.json(a, .{ .text = "large" ** 1024 }, .{ .body_bytes = 32 }));
    try std.testing.expectEqual(@as(usize, 0), rejecting.alloc_index);
    var quoted = try Packet.json(std.testing.allocator, .{ .text = "[\\\"{}]" }, .{ .depth = 1 });
    defer quoted.deinit();
    var decoder = try Decoder.init(std.testing.allocator, .{});
    defer decoder.deinit();
    const encoded = (try decoder.push(quoted.bytes.?)).body.?;
    try std.testing.expect(std.mem.indexOf(u8, encoded, "text") != null);
}
