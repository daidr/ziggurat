const std = @import("std");

pub const source = ".deps/sqlite-3.54.1/";

/// Pinned amalgamation build; no configure subprocess or network in build.
/// A missing source fails only the steps that compile it, with a fetch hint.
pub fn add(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const library = b.addLibrary(.{ .name = "sqlite-native", .linkage = .static, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    b.build_root.handle.access(source ++ "sqlite3.c", .{}) catch
        library.step.dependOn(&b.addFail("SQLite source missing; run python scripts/fetch-sqlite.py first").step);
    library.root_module.addCSourceFile(.{
        .file = b.path(source ++ "sqlite3.c"),
        .flags = &.{
            "-std=c11",
            // Connections are confined to one thread at a time; no global mutexes per connection.
            "-DSQLITE_THREADSAFE=2",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_MATH_FUNCTIONS",
            "-DSQLITE_ENABLE_RTREE",
        },
    });
    library.root_module.addIncludePath(b.path(source));
    if (target.result.os.tag == .linux) library.root_module.linkSystemLibrary("m", .{});
    module.linkLibrary(library);
    module.link_libc = true;
}
