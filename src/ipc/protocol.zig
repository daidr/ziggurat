const std = @import("std");

pub const version: u16 = 1;
pub const max_request_id = std.math.maxInt(u32);
pub const Limits = struct { max_pending: u16 = 32, max_in_flight: u16 = 8, max_message_bytes: usize = 64 * 1024 };

/// The host supplies a fresh, unpredictable session for each window document.
/// Session isolation is correlation, not a replacement for origin/frame policy.
pub const Session = struct {
    bytes: [32]u8,
    pub fn init(text: []const u8) !Session {
        if (text.len != 32) return error.InvalidSession;
        var result: Session = undefined;
        for (text, 0..) |value, index| {
            if (!std.ascii.isDigit(value) and !(value >= 'a' and value <= 'f')) return error.InvalidSession;
            result.bytes[index] = value;
        }
        return result;
    }
    pub fn eql(a: Session, b: Session) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

pub const Token = struct { session: Session, slot: u16, id: u32 };
pub const Kind = enum { call, cancel, ack };
pub const Envelope = struct {
    v: u16,
    session: []const u8,
    kind: Kind,
    slot: u16,
    id: u32,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    sequence: ?u32 = null,
};
pub const Rejection = enum { invalid_request, unsupported_version, stale_session, full, unknown_method, invalid_params, cancelled, closed, backpressure };
pub const Rejected = struct { token: Token, code: Rejection };

pub fn validateEnvelope(value: std.json.Value) !void {
    if (value != .object) return error.InvalidRequest;
    inline for (.{ "v", "slot", "id" }) |name| {
        const field = value.object.get(name) orelse return error.InvalidRequest;
        if (field != .integer) return error.InvalidRequest;
    }
    inline for (.{ "session", "kind" }) |name| {
        const field = value.object.get(name) orelse return error.InvalidRequest;
        if (field != .string) return error.InvalidRequest;
    }
    if (value.object.get("method")) |field| if (field != .null and field != .string) return error.InvalidRequest;
    if (value.object.get("sequence")) |field| if (field != .null and field != .integer) return error.InvalidRequest;
}

pub fn encode(allocator: std.mem.Allocator, value: anytype, max_bytes: usize) ![]u8 {
    // Count before allocation so oversized values cannot allocate beyond the
    // message limit. Encoding is pure: the transport is not invoked here.
    var scratch: [256]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&scratch);
    try std.json.Stringify.value(value, .{}, &counter.writer);
    if (counter.fullCount() > max_bytes) return error.MessageTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(counter.fullCount()));
    errdefer allocator.free(bytes);
    var writer: std.Io.Writer = .fixed(bytes);
    std.json.Stringify.value(value, .{}, &writer) catch return error.EncodingChanged;
    if (writer.end != bytes.len) return error.EncodingChanged;
    return bytes;
}

pub fn reject(allocator: std.mem.Allocator, token: Token, code: Rejection, max_bytes: usize) ![]u8 {
    return encode(allocator, .{ .v = version, .session = &token.session.bytes, .kind = "reject", .slot = token.slot, .id = token.id, .code = code }, max_bytes);
}
