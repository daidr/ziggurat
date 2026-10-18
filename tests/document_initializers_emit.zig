const std = @import("std");
const initializers = @import("ziggurat_document_initializers");

/// Test-only source emitter. A separate JS engine executes the exact encoded
/// batch; it does not recreate the compiler's wrapping or origin guards.
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.ExpectedOracleCase;
    const bodies: [2][]const u8 = if (std.mem.eql(u8, args[1], "return"))
        .{ "window.order.push('甲😀');var localOnly=1;return;window.order.push('unreachable');", "window.order.push(typeof localOnly);// final line comment" }
    else if (std.mem.eql(u8, args[1], "throw"))
        .{ "window.order.push('before-throw');throw new Error('expected-init-throw');", "window.order.push('unreachable');" }
    else if (std.mem.eql(u8, args[1], "guard"))
        .{ "window.order.push('first');", "window.order.push('second');" }
    else if (std.mem.eql(u8, args[1], "await"))
        .{ "await Promise.resolve();", "window.order.push('unreachable');" }
    else if (std.mem.eql(u8, args[1], "import"))
        .{ "import value from 'module';", "window.order.push('unreachable');" }
    else if (std.mem.eql(u8, args[1], "invalid-body"))
        // Deliberately invalid as an ordinary function body. It demonstrates
        // the trusted valid-body precondition; the wrapper is not a sandbox.
        .{ "});window.order.push('outside-invalid-body');(function(){", "window.order.push('guarded-second');" }
    else
        return error.UnknownOracleCase;
    const entries = [_]initializers.Initializer{
        .{ .body = bodies[0], .origins = &.{"HTTPS://EXAMPLE.test:443/"} },
        .{ .body = bodies[1], .origins = &.{"https://example.test"} },
    };
    var budget = try initializers.Budget.init(.{});
    defer std.debug.assert(budget.used == 0);
    var owned = try initializers.Owned.init(allocator, &budget, &entries);
    defer owned.deinit();
    const program = try std.unicode.utf16LeToUtf8Alloc(allocator, owned.encoded.?);
    defer allocator.free(program);
    try std.fs.File.stdout().writeAll(program);
}
