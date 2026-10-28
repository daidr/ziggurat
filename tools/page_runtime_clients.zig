//! Writes or checks the generated TypeScript clients of the page runtime's
//! services under packages/. `write <repo>` regenerates them; `check <repo>`
//! fails when a checked-in client differs from its Zig schema.
const std = @import("std");
const zio = @import("ziggurat_io");
const ipc = @import("ziggurat_ipc");
const runtime_service = @import("page_runtime_service");
const fetch_service = @import("plugin_fetch_service");
const watch_service = @import("plugin_watch_service");
const sqlite_service = @import("plugin_sqlite_service");
const websocket_service = @import("plugin_websocket_service");

const clients = .{
    .{ runtime_service.Service, "packages/runtime/src/generated/runtime.ts" },
    .{ fetch_service.Service, "packages/plugin-fetch/src/generated/fetch.ts" },
    .{ watch_service.Service, "packages/plugin-watch/src/generated/watch.ts" },
    .{ sqlite_service.Service, "packages/plugin-sqlite/src/generated/sqlite.ts" },
    .{ websocket_service.Service, "packages/plugin-websocket/src/generated/websocket.ts" },
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    if (args.len != 3) return error.Usage;
    const write = std.mem.eql(u8, args[1], "write");
    if (!write and !std.mem.eql(u8, args[1], "check")) return error.Usage;
    var root = try std.Io.Dir.cwd().openDir(zio.io(), args[2], .{});
    defer root.close(zio.io());
    var stale = false;
    inline for (clients) |client| {
        const source = try ipc.generate(client[0], allocator);
        if (write) {
            try root.createDirPath(zio.io(), std.fs.path.dirname(client[1]).?);
            try root.writeFile(zio.io(), .{ .sub_path = client[1], .data = source });
        } else {
            const current = root.readFileAlloc(zio.io(), client[1], allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => "",
                else => return err,
            };
            if (!std.mem.eql(u8, current, source)) {
                std.debug.print("{s} is out of date; run `zig build page-runtime-clients`\n", .{client[1]});
                stale = true;
            }
        }
    }
    if (stale) std.process.exit(1);
}
