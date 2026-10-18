const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");

// This is an opt-in old-public-entry RED, not a successful Find integration
// check. With allocation zero faulted, accepting the Find configuration should
// reach OutOfMemory. Frozen Linux instead rejects UnsupportedCapability before
// allocation. Do not add it to normal test/check while that gate is unchanged.
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var marker: u8 = 0;
    var fault = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var view = web.View.init(fault.allocator(), &marker, struct {
        fn event(_: *anyopaque, _: *web.View, _: web.Event) void {}
    }.event);
    const result = view.attach(window, .{
        .html = "<!doctype html><p>needle needle</p>",
        .storage = .ephemeral,
        .tools = .{ .find = true },
    });
    _ = try window.destroy();
    app.quit();
    // Construction failed before attaching Content/native WebView. quit/deinit
    // finish this unused App; run() after quit would correctly return Closed
    // and hide the original public feature rejection we are preserving.
    if (result) |_| {
        return error.UnexpectedAllocationFaultSuccess;
    } else |err| {
        std.debug.print("Linux Find public RED: actual={s} caller_allocations={d}; expected=OutOfMemory after supported-config preflight\n", .{ @errorName(err), fault.alloc_index });
        // Preserve the actual feature gap in the process result, not only a
        // generic expected-error assertion. The RED harness expects nonzero.
        if (err != error.OutOfMemory) return err;
    }
}
