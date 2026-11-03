//! Sends requests to an app's automation socket, one at a time, and reads
//! their answers, as docs/automation.md describes the protocol.
const std = @import("std");
const zio = @import("ziggurat_io");
const Problem = @import("problem.zig").Problem;

pub const Client = struct {
    stream: std.Io.net.Stream,
    arena: std.mem.Allocator,
    problem: *Problem,
    /// Bytes read past the last answer.
    pending: std.ArrayList(u8) = .empty,
    next: u64 = 0,
    /// When a request the app does not answer fails, in milliseconds since
    /// the epoch; null waits as long as it takes.
    deadline: ?i64 = null,

    /// Connects to the socket at `path`.
    pub fn connect(arena: std.mem.Allocator, path: []const u8, problem: *Problem) !Client {
        const address = std.Io.net.UnixAddress.init(path) catch |err|
            return problem.fail("cannot reach the app at {s}: {s}", .{ path, @errorName(err) });
        const stream = address.connect(zio.io()) catch |err|
            return problem.fail("cannot reach the app at {s} (did it quit? is ZIGGURAT_AUTOMATION set and the automation module started?): {s}", .{ path, @errorName(err) });
        return .{ .stream = stream, .arena = arena, .problem = problem };
    }

    pub fn close(self: *Client) void {
        self.stream.close(zio.io());
    }

    /// Sends a request and returns its result as the app wrote it. An
    /// error of the app's is `error.Failed` with its code in the problem.
    pub fn call(self: *Client, method: []const u8, params: anytype) !std.json.Value {
        self.next += 1;
        // An empty tuple would be written as an array: leave params out.
        const line = if (@typeInfo(@TypeOf(params)).@"struct".field_names.len == 0)
            try std.json.Stringify.valueAlloc(self.arena, .{ .id = self.next, .method = method }, .{})
        else
            try std.json.Stringify.valueAlloc(self.arena, .{ .id = self.next, .method = method, .params = params }, .{ .emit_null_optional_fields = false });
        zio.net.sendAll(self.stream.socket.handle, line) catch |err| return self.problem.fail("{s}: {s}", .{ method, @errorName(err) });
        zio.net.sendAll(self.stream.socket.handle, "\n") catch |err| return self.problem.fail("{s}: {s}", .{ method, @errorName(err) });
        const answer_line = try self.readLine(method);
        const answer = std.json.parseFromSliceLeaky(std.json.Value, self.arena, answer_line, .{}) catch |err|
            return self.problem.fail("{s}: the app's answer: {s}", .{ method, @errorName(err) });
        if (answer != .object) return self.problem.fail("{s}: the app's answer is no object", .{method});
        if (answer.object.get("error")) |err| {
            const code = if (err == .object) if (err.object.get("code")) |value| (if (value == .string) value.string else "failed") else "failed" else "failed";
            const message = if (err == .object) if (err.object.get("message")) |value| (if (value == .string) value.string else "") else "" else "";
            return self.problem.app(code, "{s}", .{message});
        }
        const id = answer.object.get("id") orelse .null;
        if (id != .integer or id.integer != self.next) return self.problem.fail("{s}: an answer to another request", .{method});
        return answer.object.get("result") orelse .{ .object = .empty };
    }

    fn readLine(self: *Client, method: []const u8) ![]const u8 {
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |end| {
                const line = try self.arena.dupe(u8, self.pending.items[0..end]);
                self.pending.replaceRangeAssumeCapacity(0, end + 1, &.{});
                return line;
            }
            if (self.deadline) |deadline| {
                const left = deadline - zio.milliTimestamp();
                var fds = [_]zio.net.PollFd{.{ .handle = self.stream.socket.handle }};
                const ready = if (left > 0) zio.net.pollReadable(&fds, @intCast(left)) catch 0 else 0;
                if (ready == 0) return self.problem.fail("{s}: the app did not answer in time", .{method});
            }
            const count = zio.net.receive(self.stream.socket.handle, &chunk) catch |err|
                return self.problem.fail("{s}: the app did not answer: {s}", .{ method, @errorName(err) });
            if (count == 0) return self.problem.fail("{s}: the app did not answer: it closed the connection", .{method});
            try self.pending.appendSlice(self.arena, chunk[0..count]);
        }
    }
};
