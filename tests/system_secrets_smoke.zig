//! Round trips secrets through the system credential store on a worker, with
//! results delivered on the main thread. Without `--require-store`, a Linux
//! session with no Secret Service must report CredentialStoreUnavailable for
//! every operation instead of pretending to succeed.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const secrets = system.secrets;

const service = "dev.ziggurat.smoke.secrets";
const key = "token \u{79d8}\u{5bc6}";

const Step = struct { operation: secrets.Operation, value: []const u8 = "", expect: ?anyerror = null, read: ?[]const u8 = null };

var large: [secrets.max_secret_bytes]u8 = undefined;
const Smoke = struct {
    app: *z.App,
    steps: []const Step,
    index: usize = 0,
    request: secrets.Request = undefined,
    turn: std.Thread.ResetEvent = .{},
    stop: bool = false,
    unavailable: bool = false,
    require_store: bool,
    failure: ?anyerror = null,

    fn worker(self: *Smoke) void {
        while (true) {
            self.turn.wait();
            self.turn.reset();
            if (self.stop) return;
            self.request.run() catch |err| {
                std.debug.print("post failed: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        }
    }
    fn next(self: *Smoke) void {
        if (self.index == self.steps.len) return self.finish(null);
        const step = self.steps[self.index];
        self.request = secrets.Request.init(self.app, step.operation, service, key, step.value, self, done) catch |err| return self.finish(err);
        self.turn.set();
    }
    fn done(ptr: *anyopaque, request: *secrets.Request) void {
        const self: *Smoke = @ptrCast(@alignCast(ptr));
        const failure = self.check(request);
        // Before the next step reuses the request.
        request.wipe();
        if (failure) |err| return self.finish(err);
        self.index += 1;
        self.next();
    }
    fn check(self: *Smoke, request: *secrets.Request) ?anyerror {
        const step = self.steps[self.index];
        const outcome = request.err();
        if (outcome) |err| if (err == error.CredentialStoreUnavailable) {
            if (self.require_store) return err;
            // Every operation must say the same, the first included.
            if (self.index != 0 and !self.unavailable) return error.InconsistentStore;
            self.unavailable = true;
            return null;
        };
        if (self.unavailable) return error.InconsistentStore;
        if (outcome) |err| {
            if (step.expect == null or step.expect.? != err) {
                std.debug.print("step {d}: {s}, failure {?}\n", .{ self.index, @errorName(err), request.failure });
                return error.UnexpectedOutcome;
            }
        } else if (step.expect != null) return error.UnexpectedSuccess;
        if (step.read) |expected| if (!std.mem.eql(u8, expected, request.value())) {
            std.debug.print("step {d}: read {d} bytes, expected {d}\n", .{ self.index, request.value().len, expected.len });
            return error.SecretMismatch;
        };
        return null;
    }
    fn finish(self: *Smoke, failure: ?anyerror) void {
        self.failure = failure;
        self.stop = true;
        self.turn.set();
        self.app.quit();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var require_store = builtin.os.tag == .windows;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--require-store")) require_store = true;
    }
    if (!secrets.capabilities.credential_store) return error.UnsupportedCapability;
    for (&large, 0..) |*byte, index| byte.* = @truncate(index * 7 + 3);
    const steps = [_]Step{
        .{ .operation = .delete },
        .{ .operation = .get, .expect = error.SecretNotFound },
        .{ .operation = .set, .value = &large },
        .{ .operation = .get, .read = &large },
        .{ .operation = .set, .value = "s\x00\xff\u{2603}" },
        .{ .operation = .get, .read = "s\x00\xff\u{2603}" },
        .{ .operation = .set, .value = "" },
        .{ .operation = .get, .read = "" },
        .{ .operation = .delete },
        .{ .operation = .get, .expect = error.SecretNotFound },
        .{ .operation = .delete },
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    // App.run returns at once without a window; this one is never shown.
    _ = try app.createWindow(.{ .title = "secrets", .width = 64, .height = 64 });
    var smoke: Smoke = .{ .app = app, .steps = &steps, .require_store = require_store };
    const thread = try std.Thread.spawn(.{}, Smoke.worker, .{&smoke});
    smoke.next();
    try app.run();
    thread.join();
    if (smoke.failure) |err| return err;
    if (smoke.unavailable) {
        std.debug.print("secrets: no credential store; every operation reported CredentialStoreUnavailable\n", .{});
    } else std.debug.print("secrets: {d} store operations round-tripped\n", .{steps.len});
}
