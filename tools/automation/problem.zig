//! Why a command failed, for standard error: `error.Usage` for a command
//! line used wrong (exit status 2), `error.Failed` for anything else
//! (exit status 1). `code` is the protocol's code when the app refused.
const std = @import("std");

pub const Error = error{ Usage, Failed };

pub const Problem = struct {
    buffer: [1024]u8 = undefined,
    message: []const u8 = "",
    /// The code of the app's error, as `no_element`; empty otherwise.
    code_buffer: [32]u8 = undefined,
    code: []const u8 = "",

    fn write(self: *Problem, comptime format: []const u8, args: anytype) void {
        self.message = std.fmt.bufPrint(&self.buffer, format, args) catch blk: {
            const end = "…";
            @memcpy(self.buffer[self.buffer.len - end.len ..], end);
            break :blk self.buffer[0..];
        };
    }
    pub fn usage(self: *Problem, comptime format: []const u8, args: anytype) error{Usage} {
        self.code = "";
        self.write(format, args);
        return error.Usage;
    }
    pub fn fail(self: *Problem, comptime format: []const u8, args: anytype) error{Failed} {
        self.code = "";
        self.write(format, args);
        return error.Failed;
    }
    /// An error of the protocol's table: written `code: message`.
    pub fn app(self: *Problem, code: []const u8, comptime format: []const u8, args: anytype) error{Failed} {
        const length = @min(code.len, self.code_buffer.len);
        @memcpy(self.code_buffer[0..length], code[0..length]);
        var message: [900]u8 = undefined;
        const text = std.fmt.bufPrint(&message, format, args) catch message[0..];
        self.write("{s}: {s}", .{ code, text });
        self.code = self.code_buffer[0..length];
        return error.Failed;
    }
    pub fn is(self: *const Problem, code: []const u8) bool {
        return std.mem.eql(u8, self.code, code);
    }
};
